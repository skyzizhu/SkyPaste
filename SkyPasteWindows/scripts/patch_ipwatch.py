#!/usr/bin/env python3
"""IP-change watcher for LAN sync pairing QR (both platforms).

- Desktop service watches its LAN IPv4; on change fires an event/notification.
- Settings QR auto-regenerates and shows the IP + generation time.
- Windows additionally toasts the change. Mac relies on the QR auto-refresh.
- Adds 2 localization keys x6 languages + README notes.
"""
import sys

BS = chr(92)
NL = chr(10)
Q = chr(34)

def patch(path, old, new, optional=False):
    s = open(path, encoding="utf-8").read()
    if old not in s:
        if optional:
            print(f"  (skip, anchor missing): {path} :: {old[:50]!r}")
            return 0
        print(f"ERROR: anchor missing in {path}: {old[:80]!r}")
        sys.exit(1)
    open(path, "w").write(s.replace(old, new, 1))
    return 1

changes = 0

# ============ Windows: LanSyncService ============
p = "SkyPasteWindows/src/SkyPaste.Core/Services/LanSyncService.cs"

changes += patch(p,
    "    private Timer? _pullTimer;",
    "    private Timer? _pullTimer;\n"
    "    private System.Threading.Timer? _ipMonitorTimer;\n"
    "    private string? _advertisedIP;\n\n"
    "    /// <summary>Fired (any thread) when the machine's LAN IPv4 changes.</summary>\n"
    "    public event Action<string>? IpChanged;")

changes += patch(p,
    "            _pullTimer = new Timer(_ => _ = PullPeersAsync(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(10));",
    "            _pullTimer = new Timer(_ => _ = PullPeersAsync(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(10));\n"
    "            _advertisedIP = LocalIPv4;\n"
    "            _ipMonitorTimer = new System.Threading.Timer(_ => CheckIPChange(), null, TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(15));")

changes += patch(p,
    "            _beaconTimer?.Dispose();\n            _pullTimer?.Dispose();",
    "            _beaconTimer?.Dispose();\n            _pullTimer?.Dispose();\n            _ipMonitorTimer?.Dispose();\n            _ipMonitorTimer = null;")

changes += patch(p,
    "    public void ApplyCurrentSetting()",
    "    private void CheckIPChange()" + chr(10)
    + "    {" + chr(10)
    + "            var ip = LocalIPv4;\n"
    + "            if (ip == _advertisedIP) return;\n"
    + "            _advertisedIP = ip;\n"
    + "            try { IpChanged?.Invoke(ip ?? string.Empty); } catch { }" + chr(10)
    + "    }" + NL + NL
    + "    public void ApplyCurrentSetting()")

# ============ Windows: SettingsWindow code-behind ============
p = "SkyPasteWindows/src/SkyPaste/Views/SettingsWindow.xaml.cs"

changes += patch(p,
    "        _app.LanSync.StatusChanged += UpdateLanSyncStatus;",
    "        _app.LanSync.StatusChanged += UpdateLanSyncStatus;\n"
    + "        _app.LanSync.IpChanged += OnLanIpChanged;")

changes += patch(p,
    "            _app.LanSync.StatusChanged -= UpdateLanSyncStatus;\n"
    + "            _app.HotKeys.RegistrationChanged -= UpdateHotKeyDisplay;",
    "            _app.LanSync.StatusChanged -= UpdateLanSyncStatus;\n"
    + "            _app.LanSync.IpChanged -= OnLanIpChanged;\n"
    + "            _app.HotKeys.RegistrationChanged -= UpdateHotKeyDisplay;")

changes += patch(p,
    "        QrUrlText.Text = url;",
    '        QrUrlText.Text = url;\n'
    + '        QrMetaText.Text = "IP: " + (Core.Services.LanSyncService.LocalIPv4 ?? "-")\n'
    + '            + " · " + L10n.Format("settings.lan_sync_qr_generated", DateTime.Now.ToString("HH:mm:ss"));')

changes += patch(p,
    "    private void UpdateLanSyncStatus()",
    "    private void OnLanIpChanged(string ip)" + chr(10)
    + "    {" + chr(10)
    + "        Dispatcher.Invoke(() =>" + chr(10)
    + "        {" + chr(10)
    + "            UpdateQrPanel();" + chr(10)
    + "            _app.Toast.Show(L10n.Format(\"settings.lan_sync_ip_changed_toast\", ip));" + chr(10)
    + "        });" + chr(10)
    + "    }" + NL + NL
    + "    private void UpdateLanSyncStatus()")

# ============ Windows: SettingsWindow XAML ============
p = "SkyPasteWindows/src/SkyPaste/Views/SettingsWindow.xaml"
changes += patch(p,
    '<TextBlock x:Name="QrUrlText" FontSize="10" FontFamily="Consolas, monospace"',
    '<TextBlock x:Name="QrMetaText" FontSize="10" Foreground="{DynamicResource Text.Secondary}" Margin="0,4,0,0" />\n'
    + '                                    <TextBlock x:Name="QrUrlText" FontSize="10" FontFamily="Consolas, monospace"')

# ============ macOS: LanClipboardSync ============
p = "skypaste/SkyLanClipboardSync.swift"

changes += patch(p,
    "    // MARK: - Settings surface",
    "    static var ipMonitorTimer: Timer?\n"
    + "    /// The LAN IP advertised in the current QR/bookmark.\n"
    + "    public static private(set) var advertisedIP: String?\n"
    + "    public static let ipChangedNotification = Notification.Name(\"SkyPasteLanIPChanged\")\n\n"
    + "    static func startIPMonitor() {" + NL
    + "        stopIPMonitor()" + NL
    + "        advertisedIP = localIPv4" + NL
    + "        ipMonitorTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in" + NL
    + "            let ip = localIPv4" + NL
    + "            if ip != advertisedIP {" + NL
    + "                advertisedIP = ip" + NL
    + "                DispatchQueue.main.async {" + NL
    + "                    NotificationCenter.default.post(name: ipChangedNotification, object: nil)" + NL
    + "                }" + NL
    + "            }" + NL
    + "        }" + NL
    + "    }" + NL + NL
    + "    static func stopIPMonitor() {" + NL
    + "        ipMonitorTimer?.invalidate()" + NL
    + "        ipMonitorTimer = nil" + NL
    + "    }" + NL + NL
    + "    // MARK: - Settings surface")

changes += patch(p,
    "        startServer()\n        startBeacon()\n        startPullTimer()",
    "        startServer()\n        startBeacon()\n        startPullTimer()\n        startIPMonitor()")

changes += patch(p,
    "        beaconTimer?.invalidate()\n        beaconTimer = nil\n        pullTimer?.invalidate()\n        pullTimer = nil",
    "        beaconTimer?.invalidate()\n        beaconTimer = nil\n        pullTimer?.invalidate()\n        pullTimer = nil\n        stopIPMonitor()")

# ============ macOS: SettingsView QR auto-refresh + meta caption ============
p = "skypaste/SkySettingsView.swift"

changes += patch(p,
    "    private var lanSyncEnabled: Bool {",
    "    @State private var qrTick = 0\n"
    + "    @State private var qrGeneratedAt = Date()\n\n"
    + "    private var lanSyncEnabled: Bool {")

changes += patch(p,
    "                            Text(url.absoluteString)",
    "                            Text(\"IP: \\(LanClipboardSync.localIPv4 ?? \\\"-\\\") · \"\n"
    + "                                + L10n.format(\"settings.lan_sync_qr_generated\", qrGeneratedAt.formatted(date: .omitted, time: .shortened)))\n"
    + "                                .font(.caption2)\n"
    + "                                .foregroundStyle(.secondary)\n"
    + "                                .textSelection(.enabled)\n"
    + "                            Text(url.absoluteString)")

changes += patch(p,
    "                        .padding(.top, 4)\n                    }",
    "                        .padding(.top, 4)\n"
    + "                        .id(qrTick)\n"
    + "                        .onReceive(NotificationCenter.default.publisher(for: LanClipboardSync.ipChangedNotification)) { _ in\n"
    + "                            qrGeneratedAt = Date()\n"
    + "                            qrTick += 1\n"
    + "                        }\n                    }")

# ============ Localization: 2 keys x6 (Mac strings + Windows resx script) ============
zh_generated = "二维码生成于 %@"
zh_toast = "局域网 IP 已变更为 %@，请重新扫码配对"
loc_keys = {
    "settings.lan_sync_qr_generated": {
        "en": "QR generated at %@", "zh-Hans": zh_generated, "zh-Hant": "二維碼生成於 %@",
        "ja": "QR コード生成時刻: %@", "ko": "QR 코드 생성 시각: %@", "fr": "QR généré à %@",
    },
    "settings.lan_sync_ip_changed_toast": {
        "en": "LAN IP changed to %@ — re-scan the pairing QR",
        "zh-Hans": zh_toast, "zh-Hant": "區域網路 IP 已變更為 %@，請重新掃描配對 QR",
        "ja": "LAN IP が %@ に変わりました。QR を再スキャンしてください",
        "ko": "LAN IP가 %@(으)로 변경되었습니다. QR을 다시 스캔하세요",
        "fr": "L'IP LAN a changé vers %@ — re-scannez le QR d'appairage",
    },
}
for lang in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr"]:
    path = f"skypaste/Resources/{lang}.lproj/Localizable.strings"
    content = open(path, encoding="utf-8").read()
    added = 0
    for key, per_lang in loc_keys.items():
        if f'"{key}"' not in content:
            content += f'\n"{key}" = "{per_lang[lang]}";\n'
            added += 1
    if added:
        open(path, "w", encoding="utf-8").write(content)
    print(f"mac strings {lang}: +{added}")

p = "SkyPasteWindows/scripts/make_resx.py"
s = open(p).read()
marker = '    "settings.lan_sync_qr_hint": {'
add = ""
for key, per in loc_keys.items():
    if f'"{key}"' not in s:
        block = f'    "{key}": ' + "{\n"
        for lang in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr"]:
            block += f'        "{lang}": "{per[lang]}",\n'
        block = block.rstrip("\n")[:-1] + "\n    },\n"
        add += block
if add:
    s = s.replace(marker, add + marker, 1)
    open(p, "w").write(s)
    print("resx keys added")

# ============ README notes ============
note_zh = NL + NL + "> 提示：电脑的局域网 IP 可能被路由器重新分配（DHCP）。SkyPaste 会自动检测 IP 变化并刷新设置页二维码、弹窗提醒重新扫码；建议在路由器管理页把电脑的 IP 绑定为静态（DHCP 静态租约），一劳永逸。"
note_en = NL + NL + "> Note: your computer's LAN IP may change (DHCP). SkyPaste detects the change, refreshes the pairing QR in Preferences and notifies you; consider a DHCP static reservation for the desktop on your router for a permanent fix."

p = "README.md"
s = open(p, encoding="utf-8").read()
anchor = "see the [Windows README](SkyPasteWindows/README.md) for step-by-step pairing."
if "DHCP static reservation" not in s:
    idx = s.find(anchor)
    assert idx > 0
    s = s[:idx + len(anchor)] + note_en + s[idx + len(anchor):]
    open(p, "w", encoding="utf-8").write(s)
    print("en README noted")

p = "README.zh-CN.md"
s = open(p, encoding="utf-8").read()
if "DHCP 静态租约" not in s:
    anchor = "配对教程见 [Windows README](SkyPasteWindows/README.md)"
    idx = s.find(anchor)
    if idx > 0:
        s = s[:idx + len(anchor)] + "。" + note_zh + s[idx + len(anchor):]
        open(p, "w", encoding="utf-8").write(s)
        print("zh README noted")

print(f"TOTAL: {changes} code patches")
