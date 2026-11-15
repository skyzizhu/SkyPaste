#!/usr/bin/env python3
"""Remove the token input/save UI from the web clipboard page (both platforms).

New contract: the page NEVER asks for a token.
- URL ?t= or localStorage -> use silently.
- 401 -> message 'token invalid, re-scan the desktop QR' + echo what the
  server received (diagnostic). No typing, ever.
"""
import sys

zh = "令牌无效，请重新扫描电脑端设置页的二维码打开本页"

def swift_escape(text):
    return "".join("\\u{%x}" % ord(c) for c in text)

def patch(path, is_swift):
    s = open(path).read()
    changes = 0

    # 1) Remove the tokenBox HTML section.
    start = s.find('<section id="tokenBox"')
    if start != -1:
        end = s.find("</section>", start) + len("</section>")
        # also swallow the trailing newline
        if s[end:end+1] == "\n":
            end += 1
        s = s[:start] + s[end:]
        changes += 1

    # 2) Remove showTokenBox + saveToken functions.
    for marker_end_pairs in [
        ("function showTokenBox(prefill) {", "}\n"),
        ("function saveToken() {", "}\n"),
    ]:
        start = s.find(marker_end_pairs[0])
        if start != -1:
            end = s.find(marker_end_pairs[1], start) + len(marker_end_pairs[1])
            s = s[:start] + s[end:]
            changes += 1

    # 3) Sanitize the ?t= token from the URL.
    old_boot = "let token = params.get('t') || localStorage.getItem('sp_token') || '';"
    new_boot = (
        "let token = sanitizeToken(params.get('t')) "
        "|| localStorage.getItem('sp_token') || '';"
    )
    if old_boot in s:
        s = s.replace(old_boot, new_boot)
        changes += 1

    # 4) 401 handler: no box; clear bad token; guide to re-scan; show server received.
    old_401 = (
        "    let provided = '';\n"
        "    try { const j = await r.json(); provided = j.provided || ''; } catch (e2) {}\n"
        "    showTokenBox(provided);\n"
    )
    new_401 = (
        "    let provided = '';\n"
        "    try { const j = await r.json(); provided = j.provided || ''; } catch (e2) {}\n"
        "    localStorage.removeItem('sp_token');\n"
    )
    if old_401 in s:
        s = s.replace(old_401, new_401)
        changes += 1

    old_msg = "msg('server received: \"' + provided + '\");"
    if is_swift:
        zh_escaped = swift_escape(zh)
        new_msg = "msg('" + zh_escaped + " server received: \"' + provided + '\"');"
    else:
        new_msg = "msg('" + zh + " server received: \"' + provided + '\");"
    if old_msg in s:
        s = s.replace(old_msg, new_msg)
        changes += 1

    # 5) sendText/pull: drop the tokenInput auto-apply lines (no box anymore).
    old_box = (
        "  const boxToken = document.getElementById('tokenInput').value.trim();\n"
        "  if (boxToken && boxToken !== token) { token = boxToken; localStorage.setItem('sp_token', token); }\n"
    )
    while old_box in s:
        s = s.replace(old_box, "")
        changes += 1

    open(path, "w").write(s)
    return changes

total = 0
for path, is_swift in [
    ("skypaste/SkyLanClipboardSync.swift", True),
    ("SkyPasteWindows/src/SkyPaste.Core/Services/WebClipboardPageBuilder.cs", False),
]:
    n = patch(path, is_swift)
    total += n
    print(f"{path}: {n} changes")

if total < 8:
    print("WARNING: fewer changes than expected")
    sys.exit(1)
print("OK")
