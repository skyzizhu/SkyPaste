#!/usr/bin/env python3
"""Sync the (verified-correct) web clipboard script from the Mac page into the
Windows builder, replacing whatever script block is there."""
import sys, re

# 1) Extract the verified script from the macOS Swift page.
mac = open("skypaste/SkyLanClipboardSync.swift", encoding="utf-8").read()
start = mac.find("<script>")
end = mac.find("</script>")
if start == -1 or end == -1:
    print("ERROR: script block not found in Swift page")
    sys.exit(1)
script = mac[start + len("<script>"):end]

# Sanity: the script must be the fixed version and must parse.
assert "Object.assign({ headers: {} }, opts)" in script, "header merge fix missing"
assert "boxToken" not in script, "stray boxToken present"
assert 'provided = j.provided' in script, "401 diagnostic missing"

# 2) Replace the Windows builder's script block with the same content.
p = "SkyPasteWindows/src/SkyPaste.Core/Services/WebClipboardPageBuilder.cs"
s = open(p, encoding="utf-8").read()
w_start = s.find("<script>")
w_end = s.find("</script>")
if w_start == -1 or w_end == -1:
    print("ERROR: script block not found in C# builder")
    sys.exit(1)

old_script = s[w_start + len("<script>"):w_end]
print("replacing", len(old_script), "chars with", len(script), "chars")
s = s[:w_start + len("<script>")] + script + s[w_end:]
open(p, "w", encoding="utf-8").write(s)
print("OK: Windows page script synced from the verified macOS page")
