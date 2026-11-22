#!/usr/bin/env python3
"""Generate WebClipboardPageBuilder.cs from the live verified page served by
the macOS app (the page that passed node --check and real-device testing).

Splits the captured HTML at the device-name occurrences and emits three C#
verbatim-string segments; Build() re-assembles them with the escaped name.
"""
import sys

PAGE_FILE = "/tmp/verified_page.html"
DEVICE_NAME = "Skyzizhu的Mac Studio"  # the running instance's name
OUT = "src/SkyPaste.Core/Services/WebClipboardPageBuilder.cs"

html = open(PAGE_FILE, encoding="utf-8").read()
if DEVICE_NAME not in html:
    print(f"ERROR: device name {DEVICE_NAME!r} not found in captured page")
    sys.exit(1)

# Replace the live instance's name with a marker BEFORE splitting, so no real
# device name gets baked into the generated code.
MARKER = "\x00DEVICE\x00"
parts = html.replace(DEVICE_NAME, MARKER).split(MARKER)
if len(parts) != 3:
    print(f"ERROR: expected exactly 2 device-name occurrences, got {len(parts) - 1}")
    sys.exit(1)

def verbatim(text):
    # C# verbatim string: double the quotes, keep everything else literal.
    return '@"' + text.replace('"', '""') + '"'

def csharp_string(text):
    # For short lines needing escapes: use a normal escaped string.
    out = text.replace(BS, BS + BS).replace(Q, BS + Q)
    return Q + out + Q

BS = chr(92)
Q = chr(34)
NL = chr(10)
TAB = "    "

body_parts = []
for index, part in enumerate(parts):
    body_parts.append(TAB + "private const string Part%d = " % (index,) + verbatim(part) + ";")

file_content = """using System.Text;

namespace SkyPaste.Core.Services;

/// <summary>
/// Builds the web clipboard page served by the LAN sync HTTP service (GET /).
/// Phones open it via the pairing QR/URL — no app install. The token arrives
/// via ?t= and is persisted in localStorage; the page shell contains no
/// secrets. The page content is captured verbatim from the verified macOS
/// implementation (scripts kept byte-identical across platforms).
/// </summary>
public static class WebClipboardPageBuilder
{
    public static string Build(string deviceName)
    {
        return Part0 + Escape(deviceName) + Part1 + Escape(deviceName) + Part2;
    }

    // Page segments split at the two device-name occurrences (title + header).
""" + NL.join(body_parts) + """

    /// <summary>Escapes text interpolated into HTML contexts (title/header).</summary>
    private static string Escape(string value) =>
        value
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\\"", "&quot;");
}
"""

open(OUT, "w", encoding="utf-8").write(file_content)
print(f"OK: wrote {OUT} ({len(file_content)} chars, segments {len(parts[0])}/{len(parts[1])}/{len(parts[2])})")
