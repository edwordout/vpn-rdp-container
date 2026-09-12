# Split RDP audio over SSH

## Purpose

On some high-latency routes, RDP graphics and audio interfere because both share the same ordered transport. Visible graphics can then delay audio enough to cause gaps or corruption.

For SSH-tunnel access, this project can move audio onto a second SSH/TCP connection. Graphics, input, and clipboard remain on RDP; host `pw-play` receives the separate audio stream.

## Enabling it

```bash
RDP_ACCESS_MODE='ssh-tunnel'
RDP_SPLIT_AUDIO='1'
```

`RDP_SPLIT_AUDIO` defaults to `0`. It is ignored in direct access mode. When disabled, audio uses normal XRDP sound redirection.

## Data flow

```text
RDP client ── SSH forward ──> XRDP graphics/input/clipboard

Container playback
  └─> PipeWire ssh_audio sink
      └─> ssh_audio.monitor
          └─> separate SSH connection
              └─> host pw-play
```

The audio launcher explicitly disables SSH connection multiplexing and inherited forwarding. This forces audio onto a different TCP connection instead of placing it behind RDP traffic on the existing SSH connection.

The managed SSH key remains restricted. It permits the RDP port forward and, when split audio is enabled, only the forced `stream-audio` command, not an arbitrary remote shell.

## Lifecycle

Start the outer RDP connection first so the XRDP PipeWire session exists. Then run `run-rdp-audio.sh`, or place `run-rdp-audio.sh companion` beside the real RDP connection in a RustConn group and use **Connect All**.

While running, the remote helper creates `ssh_audio`, makes it the default sink, and moves playback streams to it. On shutdown it restores the previous sink, moves playback back, and removes the temporary sink.

RustConn 0.21.10 does not run post-disconnect tasks for external RDP sessions. Use the group’s **Disconnect All** action to stop both the RDP connection and audio companion deterministically.
