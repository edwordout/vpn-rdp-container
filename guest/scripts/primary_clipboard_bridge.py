#!/usr/bin/python3
import fcntl
import hashlib
import os
import re
import signal
import subprocess
import sys
import time

XCLIP = "/usr/bin/xclip"
POLL_INTERVAL_SECONDS = 0.3
DISPLAY_ERROR_LIMIT = 3


def log(message):
    sys.stdout.write(f"{message}\n")
    sys.stdout.flush()


def normalize_display(display):
    display = display.strip()
    match = re.fullmatch(r"(?:(?P<host>[^:]*):)?(?P<number>[0-9]+)(?:\.[0-9]+)?", display)
    if match is None:
        return display

    host = match.group("host").lower()
    if host in ("", "unix", "unix/"):
        host = "local"
    return f"{host}:{match.group('number')}"


def display_key(display):
    return hashlib.sha256(os.fsencode(normalize_display(display))).hexdigest()[:16]


def display_lock_path(display):
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "")
    if not (os.path.isabs(runtime_dir) and os.path.isdir(runtime_dir)):
        runtime_dir = "/tmp"
    return os.path.join(
        runtime_dir,
        f"primary-clipboard-bridge.{os.getuid()}.{display_key(display)}.lock",
    )


def proc_start_time(pid):
    try:
        with open(f"/proc/{pid}/stat", "r", encoding="utf-8") as stat_file:
            stat = stat_file.read()
        _comm, remainder = stat.rsplit(") ", 1)
        parts = remainder.split()
        return parts[19]
    except (OSError, IndexError, ValueError):
        return None


def session_parent_pid():
    env_pid = os.environ.get("XRDP_SESSION_PID", "")
    try:
        parent_pid = int(env_pid)
    except ValueError:
        parent_pid = 0
    if parent_pid > 0:
        return parent_pid
    return os.getppid()


def session_parent_exited(pid, start_time):
    if pid <= 1:
        return True
    if os.getppid() != pid:
        return True
    current_start_time = proc_start_time(pid)
    if current_start_time is None:
        return True
    return current_start_time != start_time


def acquire_display_lock(display, parent_pid):
    lock_path = display_lock_path(display)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    os.set_inheritable(fd, False)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log(f"Another primary clipboard bridge already owns DISPLAY={display}; exiting.")
        os.close(fd)
        return None

    metadata = "".join(
        (
            f"pid={os.getpid()}\n",
            f"ppid={parent_pid}\n",
            f"display={display}\n",
            f"normalized_display={normalize_display(display)}\n",
        )
    )
    os.ftruncate(fd, 0)
    os.write(fd, metadata.encode())
    os.fsync(fd)
    return fd


def is_display_error(stderr):
    lower_stderr = stderr.lower()
    return (
        b"can't open display" in lower_stderr
        or b"cannot open display" in lower_stderr
        or b"unable to open display" in lower_stderr
    )


def read_selection(selection):
    try:
        completed = subprocess.run(
            [XCLIP, "-selection", selection, "-o"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            timeout=2,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return b"", True

    if completed.returncode == 0:
        return completed.stdout, False
    if is_display_error(completed.stderr):
        return b"", True
    return b"", False


def write_selection(selection, payload):
    if payload == b"":
        return False
    try:
        completed = subprocess.run(
            [XCLIP, "-selection", selection],
            input=payload,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            close_fds=True,
            timeout=2,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return False
    return completed.returncode == 0


def main():
    display = os.environ.get("DISPLAY", "")
    if display == "":
        log("DISPLAY is not set; clipboard bridge exiting.")
        return 0

    if not os.access(XCLIP, os.X_OK):
        log("xclip is not executable at /usr/bin/xclip; clipboard bridge exiting.")
        return 0

    parent_pid = session_parent_pid()
    parent_start_time = proc_start_time(parent_pid)
    if parent_start_time is None:
        log(f"Session parent pid={parent_pid} is not inspectable; clipboard bridge exiting.")
        return 0

    lock_fd = acquire_display_lock(display, parent_pid)
    if lock_fd is None:
        return 0

    lock_path = display_lock_path(display)
    running = {"value": True}

    def stop(signum, _frame):
        running["value"] = False
        log(f"Stopping primary clipboard bridge pid={os.getpid()} signal={signum}")

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, stop)

    log(
        "Starting primary clipboard bridge "
        f"pid={os.getpid()} ppid={parent_pid} display={display} "
        f"normalized_display={normalize_display(display)} lock={lock_path}"
    )

    primary_last = None
    clipboard_last = None
    display_errors = 0

    try:
        while running["value"]:
            if session_parent_exited(parent_pid, parent_start_time):
                log("Parent session process exited; stopping primary clipboard bridge.")
                break

            primary_text, primary_error = read_selection("primary")
            clipboard_text, clipboard_error = read_selection("clipboard")

            if primary_error or clipboard_error:
                display_errors += 1
                if display_errors >= DISPLAY_ERROR_LIMIT:
                    log(f"Lost access to DISPLAY={display}; stopping primary clipboard bridge.")
                    break
                time.sleep(POLL_INTERVAL_SECONDS)
                continue

            display_errors = 0

            if primary_text and primary_text != primary_last and primary_text != clipboard_text:
                if write_selection("clipboard", primary_text):
                    clipboard_text = primary_text
            elif clipboard_text and clipboard_text != clipboard_last and clipboard_text != primary_text:
                if write_selection("primary", clipboard_text):
                    primary_text = clipboard_text

            primary_last = primary_text
            clipboard_last = clipboard_text
            time.sleep(POLL_INTERVAL_SECONDS)
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)
        try:
            os.unlink(lock_path)
        except OSError:
            pass

    return 0


raise SystemExit(main())
