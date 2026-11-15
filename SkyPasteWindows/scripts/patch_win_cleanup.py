#!/usr/bin/env python3
"""Windows builder page: remove stray boxToken lines + fix 401 msg concat."""
import sys

p = "SkyPasteWindows/src/SkyPaste.Core/Services/WebClipboardPageBuilder.cs"
s = open(p).read()
changes = 0

# 1) Remove both stray boxToken if-lines (sendText + pull).
stray = "  if (boxToken && boxToken !== token) { token = boxToken; localStorage.setItem('sp_token', token); }\n"
while stray in s:
    s = s.replace(stray, "", 1)
    changes += 1

# 2) Fix the mangled 401 msg (literal concat text instead of JS concatenation).
mangled = "msg('server received: \" + provided + \"');"
proper = "msg('server received: \"' + provided + '\");"
if mangled in s:
    s = s.replace(mangled, proper, 1)
    changes += 1

open(p, "w").write(s)

# Sanity: no boxToken may remain anywhere in the builder.
if "boxToken" in s:
    print("ERROR: boxToken still referenced:")
    for line in s.split("\n"):
        if "boxToken" in line:
            print("   ", line)
    sys.exit(1)
print(f"OK: {changes} changes, no boxToken references remain")
