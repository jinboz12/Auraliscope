#!/usr/bin/env python3
"""Lists the Auraliscope Bridge identities saved in a REAPER project (.rpp): one line per insert, and whether they
are all distinct. The plugin state is base64 inside each <VST …> or <AU …> block; the Bridge's own text in it
carries "id=<32 hex digits>"."""
import base64, re, sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
ids = []
for block in re.finditer(r"^\s*<(VST|AU) \"([^\"]*Auraliscope Bridge[^\"]*)\"[^\n]*\n(.*?)^\s*>", text, re.S | re.M):
    payload = "".join(line.strip() for line in block.group(3).splitlines() if re.fullmatch(r"[A-Za-z0-9+/=]+", line.strip()))
    try:
        data = base64.b64decode(payload + "=" * (-len(payload) % 4))
    except Exception:
        data = b""
    # An AU's state is a property list, with the Bridge's own text base64-encoded once more inside it.
    inner = re.search(rb"<key>com\.jinboz\.AuraliscopeBridge\.state</key>\s*<data>(.*?)</data>", data, re.S)
    if inner:
        data = base64.b64decode(re.sub(rb"\s", b"", inner.group(1)))
    found = re.search(rb"id=([0-9A-F]{32})", data)
    name = re.search(rb"name=([^\n]*)", data)
    ids.append(found.group(1).decode() if found else None)
    print(f"{block.group(2)}: id {ids[-1] or '?'}, name \"{name.group(1).decode(errors='replace') if name else ''}\"")
distinct = len(ids) >= 2 and None not in ids and len(set(ids)) == len(ids)
print(f"{len(ids)} Bridge insert(s) saved; identities {'all distinct: PASS' if distinct else 'NOT distinct: FAIL'}")
sys.exit(0 if distinct else 1)
