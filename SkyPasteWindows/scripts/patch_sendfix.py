#!/usr/bin/env python3
"""Fix the Mac web page: remove stray boxToken reference (ReferenceError on send)
and repair the 401 message concatenation."""
import sys

p = "skypaste/SkyLanClipboardSync.swift"
s = open(p).read()
changes = 0

# 1) Remove the stray boxToken if-line (leftover after the input UI removal).
stray = "  if (boxToken && boxToken !== token) { token = boxToken; localStorage.setItem('sp_token', token); }\n"
while stray in s:
    s = s.replace(stray, "", 1)
    changes += 1

# 2) Repair the 401 msg: proper JS concatenation (raw double quotes are fine
#    inside Swift multiline strings).
broken = "msg('server received: \"' + provided + '\");"
fixed = "msg(\"server received: \\\"\" + provided + \"\\\"\");"
# The file currently holds the mangled literal (no concatenation). Replace by
# locating the unique prefix.
mangled = "msg('server received: \" + provided + \"');"
if mangled in s:
    s = s.replace(mangled, fixed, 1)
    changes += 1

open(p, "w").write(s)
print(f"{changes} changes")

# Sanity: no boxToken references may remain in the page string.
if "boxToken" in s:
    print("WARNING: boxToken still referenced:")
    for line in s.split("\n"):
        if "boxToken" in line:
            print("   ", line)
    sys.exit(1)
print("OK: no boxToken references remain")
