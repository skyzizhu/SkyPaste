#!/usr/bin/env python3
"""Add a dedicated lanDevice source so phone/LAN pushes no longer show the
iCloud badge on macOS."""

def patch(path, old, new):
    s = open(path, encoding="utf-8").read()
    assert old in s, (path, old[:70])
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))

# 1) ClipboardSource: new case + badge/icon/keywords
p = "skypaste/SkyClipboardItem.swift"

patch(p,
"""enum ClipboardSource: Int, Equatable {
    case local = 0
    case universalClipboard = 1
    case cloudKit = 2
""",
"""enum ClipboardSource: Int, Equatable {
    case local = 0
    case universalClipboard = 1
    case cloudKit = 2
    case lanDevice = 3
""")

patch(p,
"""    var isDeviceSynced: Bool {
        self == .universalClipboard || self == .cloudKit
    }
""",
"""    var isDeviceSynced: Bool {
        self == .universalClipboard || self == .cloudKit || self == .lanDevice
    }
""")

patch(p,
"""        case .cloudKit:
            return "icloud"
        }
    }
""",
"""        case .cloudKit:
            return "icloud"
        case .lanDevice:
            return "wifi"
        }
    }
""")

patch(p,
"""        case .cloudKit:
            return L10n.tr("clipboard.source.icloud")
        }
    }
""",
"""        case .cloudKit:
            return L10n.tr("clipboard.source.icloud")
        case .lanDevice:
            return L10n.tr("clipboard.source.lan")
        }
    }
""")

patch(p,
"""        case .cloudKit:
            return ["icloud", "cloud", "sync", "云", "云同步", "icloud sync"]
        }
    }
""",
"""        case .cloudKit:
            return ["icloud", "cloud", "sync", "云", "云同步", "icloud sync"]
        case .lanDevice:
            return ["lan", "device", "手机", "设备", "局域网", "同步"]
        }
    }
""")
print("1) ClipboardSource patched")

# 2) LAN sync service: push/pull items carry .lanDevice (not .cloudKit)
p = "skypaste/SkyLanClipboardSync.swift"
import re
s = open(p, encoding="utf-8").read()
n = s.count("source: .cloudKit")
s = s.replace("source: .cloudKit", "source: .lanDevice")
open(p, "w", encoding="utf-8").write(s)
print(f"2) LAN service: {n} usages switched to .lanDevice")

# 3) Localization: clipboard.source.lan x6
loc = {
    "en": "LAN Sync",
    "zh-Hans": "局域网同步",
    "zh-Hant": "區域網路同步",
    "ja": "LAN同期",
    "ko": "LAN 동기화",
    "fr": "Synchronisation LAN",
}
for lang, value in loc.items():
    path = f"skypaste/Resources/{lang}.lproj/Localizable.strings"
    content = open(path, encoding="utf-8").read()
    if '"clipboard.source.lan"' not in content:
        content += f'\n"clipboard.source.lan" = "{value}";\n'
        open(path, "w", encoding="utf-8").write(content)
        print(f"3) strings {lang}: +1")
print("OK")
