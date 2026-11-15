#!/usr/bin/env python3
"""Fix api() header merge: opts.headers must MERGE with the token header,
not replace it. This is why every phone POST lost X-SkyPaste-Token (401)
while GET /pull worked."""
import sys

BS = chr(92)
Q = chr(39)

broken = (
    "async function api(path, opts) {"
    + " return fetch(path, Object.assign({ headers: { 'X-SkyPaste-Token': token } }, opts));"
)
# Tolerate whitespace variants: build the search as a regex-free scan.
marker = "async function api(path, opts)"

fixed = (
    "async function api(path, opts) {" + chr(10)
    + "  const merged = Object.assign({ headers: {} }, opts);" + chr(10)
    + "  merged.headers = Object.assign({ 'X-SkyPaste-Token': token }, merged.headers || {});" + chr(10)
    + "  return fetch(path, merged);"
)

for p in ["skypaste/SkyLanClipboardSync.swift",
          "SkyPasteWindows/src/SkyPaste.Core/Services/WebClipboardPageBuilder.cs"]:
    s = open(p).read()
    i = s.find(marker)
    if i == -1:
        print(f"ERROR: api() not found in {p}")
        sys.exit(1)
    # Find the end of the api function: the line starting with '  return fetch(path'
    j = s.find("return fetch(path", i)
    end = s.find(chr(10), j)
    old_body = s[i:end]
    s = s[:i] + fixed + s[end:]
    open(p, "w").write(s)
    print(f"patched {p}")
    print("  old:", repr(old_body))
print("OK")
