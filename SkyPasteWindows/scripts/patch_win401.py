#!/usr/bin/env python3
"""Repair the mangled Windows 401 diagnostic statement (previous bash patch)."""
import sys

p = "SkyPasteWindows/src/SkyPaste.Core/Services/LanSyncService.cs"
lines = open(p).read().split("\n")

BS = chr(92)
Q = chr(34)
JSON_ESC = BS + Q  # two chars: backslash + quote (C# escape for a quote)

# Correct C# lines:
safe_line = (
    '            var safe = (request.Header("X-SkyPaste-Token") ?? "(none)")'
    + '.Replace("' + BS + BS + '", "");'
)
return_line = (
    '            return (401, "' + "{"
    + JSON_ESC + "error" + JSON_ESC + ":" + JSON_ESC + "unauthorized" + JSON_ESC + ","
    + JSON_ESC + "provided" + JSON_ESC + ":" + JSON_ESC + '" + safe + "'
    + JSON_ESC + "," + JSON_ESC + "expectedLen" + JSON_ESC + ":"
    + '" + _settings.LanSyncToken.Length + "}'
    + Q + ");"
)

# Locate the broken return line.
target = None
for i, line in enumerate(lines):
    if "return (401," in line and 'provided' in line:
        target = i
        break
if target is None:
    print("ERROR: broken return line not found")
    sys.exit(1)

# The broken safe line is immediately before it.
lines[target - 1] = safe_line
lines[target] = return_line

open(p, "w").write("\n".join(lines))
print("OK: repaired lines", target, "->", target + 1)
