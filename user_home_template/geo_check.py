#!/usr/bin/env python3
import os
from urllib.request import urlopen
import json
from pprint import pprint as pp

REQUIRE_COUNTRY = os.environ['REQUIRE_COUNTRY'].upper()

with urlopen("http://ip-api.com/json", timeout=10) as r:
    body = json.loads(r.read())

print()
pp(body)
print()

assert body.get("countryCode", "").upper() == REQUIRE_COUNTRY, f"IP not in {REQUIRE_COUNTRY}!\n"
