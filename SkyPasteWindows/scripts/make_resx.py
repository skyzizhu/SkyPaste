#!/usr/bin/env python3
"""Convert macOS .strings localization files into .NET .resx files.

Reads skypaste/Resources/<lang>.lproj/Localizable.strings from the sibling
macOS project, applies platform adaptations (Finder -> Explorer, Cmd -> Ctrl,
iCloud sync -> LAN sync, ...), and writes Strings.resx (+ language variants)
into src/SkyPaste/Localization/.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STRINGS_DIR = os.path.join(ROOT, "skypaste", "Resources")
OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src", "SkyPaste.Core", "Localization"))

LANGS = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr"]

# key renames: old -> new
RENAMES = {
    "menu.reveal_in_finder": "menu.reveal_in_explorer",
    "hotkey.cmd": "hotkey.ctrl",
    "hotkey.option": "hotkey.alt",
    "settings.command": "settings.ctrl",
    "settings.option": "settings.alt",
    "clipboard.source.universal": "clipboard.source.device",
    "settings.universal_clipboard": "settings.lan_sync",
    "settings.universal_clipboard_hint": "settings.lan_sync_hint",
    "settings.icloud_sync": None,  # dropped (merged into lan_sync)
    "settings.icloud_sync_upload": "settings.lan_sync_upload",
    "settings.icloud_sync_receive": "settings.lan_sync_receive",
    "settings.icloud_sync_hint": "settings.lan_sync_hint2",
    "settings.icloud_sync_rules_hint": "settings.lan_sync_rules_hint",
    "settings.icloud_sync_status_disabled": "settings.lan_sync_status_disabled",
    "settings.icloud_sync_status_unavailable": "settings.lan_sync_status_unavailable",
    "settings.icloud_sync_status_syncing": "settings.lan_sync_status_syncing",
    "settings.icloud_sync_status_synced": "settings.lan_sync_status_synced",
    "settings.icloud_sync_status_error": "settings.lan_sync_status_error",
    "filter.source_phone": "filter.source_device",
}

# fully re-authored values per key, per language
OVERRIDES: dict[str, dict[str, str]] = {
    "menu.reveal_in_explorer": {
        "en": "Reveal in Explorer",
        "zh-Hans": "在资源管理器中显示",
        "zh-Hant": "在檔案總管中顯示",
        "ja": "エクスプローラーで表示",
        "ko": "탐색기에서 표시",
        "fr": "Afficher dans l'Explorateur",
    },
    "panel.shortcut_hint": {
        "en": "Enter: Paste  ·  ↑/↓: Navigate  ·  Esc: Close  ·  Ctrl+1...9: Quick Copy",
        "zh-Hans": "Enter：粘贴  ·  ↑/↓：导航  ·  Esc：关闭  ·  Ctrl+1...9：快捷复制",
        "zh-Hant": "Enter：貼上  ·  ↑/↓：導航  ·  Esc：關閉  ·  Ctrl+1...9：快捷複製",
        "ja": "Enter：貼り付け  ·  ↑/↓：移動  ·  Esc：閉じる  ·  Ctrl+1...9：クイックコピー",
        "ko": "Enter: 붙여넣기  ·  ↑/↓: 탐색  ·  Esc: 닫기  ·  Ctrl+1...9: 빠른 복사",
        "fr": "Entrée : coller  ·  ↑/↓ : naviguer  ·  Échap : fermer  ·  Ctrl+1...9 : copie rapide",
    },
    "panel.shortcut_hint_copy_only": {
        "en": "Enter: Copy  ·  ↑/↓: Navigate  ·  Esc: Close  ·  Ctrl+1...9: Quick Copy",
        "zh-Hans": "Enter：复制  ·  ↑/↓：导航  ·  Esc：关闭  ·  Ctrl+1...9：快捷复制",
        "zh-Hant": "Enter：複製  ·  ↑/↓：導航  ·  Esc：關閉  ·  Ctrl+1...9：快捷複製",
        "ja": "Enter：コピー  ·  ↑/↓：移動  ·  Esc：閉じる  ·  Ctrl+1...9：クイックコピー",
        "ko": "Enter: 복사  ·  ↑/↓: 탐색  ·  Esc: 닫기  ·  Ctrl+1...9: 빠른 복사",
        "fr": "Entrée : copier  ·  ↑/↓ : naviguer  ·  Échap : fermer  ·  Ctrl+1...9 : copie rapide",
    },
    "menu.command_c_copy": {
        "en": "ctrl+c copy",
        "zh-Hans": "ctrl+c 复制",
        "zh-Hant": "ctrl+c 複製",
        "ja": "ctrl+c コピー",
        "ko": "ctrl+c 복사",
        "fr": "copie ctrl+c",
    },
    "settings.launch_at_login_hint": {
        "en": "Runs automatically when you sign in to Windows.",
        "zh-Hans": "登录 Windows 后自动启动。",
        "zh-Hant": "登入 Windows 後自動啟動。",
        "ja": "Windows にサインインしたときに自動的に起動します。",
        "ko": "Windows에 로그인하면 자동으로 시작됩니다.",
        "fr": "Se lance automatiquement à l'ouverture de session Windows.",
    },
    "settings.sync": {
        "en": "Sync & Privacy",
        "zh-Hans": "同步与隐私",
        "zh-Hant": "同步與隱私",
        "ja": "同期とプライバシー",
        "ko": "동기화 및 개인정보",
        "fr": "Synchronisation et confidentialité",
    },
    "settings.lan_sync_hint": {
        "en": "Runs a small LAN service so your phone or other PCs can send clipboard content to SkyPaste.",
        "zh-Hans": "在局域网内开放小型同步服务，手机或其他电脑可把剪贴板内容发送到 SkyPaste。",
        "zh-Hant": "在區域網路內開放小型同步服務，手機或其他電腦可將剪貼簿內容傳送到 SkyPaste。",
        "ja": "LAN 内に小さな同期サービスを公開し、スマホや他の PC からクリップボードの内容を送信できます。",
        "ko": "LAN에서 작은 동기화 서비스를 열어 휴대폰이나 다른 PC에서 클립보드 내용을 보낼 수 있습니다.",
        "fr": "Expose un petit service local pour que votre téléphone ou d'autres PC puissent envoyer du contenu vers SkyPaste.",
    },
    "settings.lan_sync_rules_hint": {
        "en": "Control whether SkyPaste uploads text copied on this PC, receives content from devices, or both.",
        "zh-Hans": "控制 SkyPaste 是否上传本机复制的文本、接收设备内容，或两者都启用。",
        "zh-Hant": "控制 SkyPaste 是否上傳本機複製的文字、接收裝置內容，或兩者皆啟用。",
        "ja": "この PC でコピーしたテキストの送信、デバイスからの受信、またはその両方を制御します。",
        "ko": "이 PC에서 복사한 텍스트 업로드, 기기에서 수신 또는 둘 다를 제어합니다.",
        "fr": "Contrôlez l'envoi du texte copié sur ce PC, la réception depuis des appareils, ou les deux.",
    },
    "settings.lan_sync_status_disabled": {
        "en": "LAN Sync is off.",
        "zh-Hans": "局域网同步未开启。",
        "zh-Hant": "區域網路同步未開啟。",
        "ja": "LAN 同期はオフです。",
        "ko": "LAN 동기화가 꺼져 있습니다.",
        "fr": "La synchronisation LAN est désactivée.",
    },
    "settings.lan_sync_status_unavailable": {
        "en": "LAN Sync could not start. Check the port setting.",
        "zh-Hans": "局域网同步无法启动，请检查端口设置。",
        "zh-Hant": "區域網路同步無法啟動，請檢查連接埠設定。",
        "ja": "LAN 同期を開始できませんでした。ポート設定を確認してください。",
        "ko": "LAN 동기화를 시작할 수 없습니다. 포트 설정을 확인하세요.",
        "fr": "Impossible de démarrer la synchronisation LAN. Vérifiez le port.",
    },
    "settings.lan_sync_status_syncing": {
        "en": "Syncing over LAN...",
        "zh-Hans": "正在通过局域网同步…",
        "zh-Hant": "正在透過區域網路同步…",
        "ja": "LAN 経由で同期中…",
        "ko": "LAN을 통해 동기화 중…",
        "fr": "Synchronisation via le LAN…",
    },
    "settings.lan_sync_status_synced": {
        "en": "LAN Sync is on.",
        "zh-Hans": "局域网同步已开启。",
        "zh-Hant": "區域網路同步已開啟。",
        "ja": "LAN 同期はオンです。",
        "ko": "LAN 동기화가 켜져 있습니다.",
        "fr": "La synchronisation LAN est activée.",
    },
    "clipboard.source.device": {
        "en": "Device",
        "zh-Hans": "设备同步",
        "zh-Hant": "裝置同步",
        "ja": "デバイス同期",
        "ko": "기기 동기화",
        "fr": "Appareil",
    },
}

# brand-new keys that do not exist on macOS
NEW_KEYS: dict[str, dict[str, str]] = {
    "settings.lan_sync_device_name": {
        "en": "Device name",
        "zh-Hans": "设备名称",
        "zh-Hant": "裝置名稱",
        "ja": "デバイス名",
        "ko": "장치 이름",
        "fr": "Nom de l'appareil",
    },
    "settings.lan_sync_port": {
        "en": "Port",
        "zh-Hans": "端口",
        "zh-Hant": "連接埠",
        "ja": "ポート",
        "ko": "포트",
        "fr": "Port",
    },
    "settings.lan_sync_token": {
        "en": "Pairing token",
        "zh-Hans": "配对令牌",
        "zh-Hant": "配對權杖",
        "ja": "ペアリングトークン",
        "ko": "페어링 토큰",
        "fr": "Jeton d'appairage",
    },
    "settings.lan_sync_token_hint": {
        "en": "Send clipboard from your phone with the X-SkyPaste-Token header. See README for iOS Shortcuts and Android steps.",
        "zh-Hans": "手机发送剪贴板时请携带 X-SkyPaste-Token 请求头。iOS 快捷指令与 Android 配置步骤见 README。",
        "zh-Hant": "手機傳送剪貼簿時請攜帶 X-SkyPaste-Token 請求標頭。iOS 捷徑與 Android 設定步驟見 README。",
        "ja": "スマホから送信する場合は X-SkyPaste-Token ヘッダーを付けてください。手順は README を参照。",
        "ko": "휴대폰에서 보낼 때 X-SkyPaste-Token 헤더를 포함하세요. 자세한 단계는 README를 참고하세요.",
        "fr": "Envoyez le presse-papiers depuis votre téléphone avec l'en-tête X-SkyPaste-Token. Voir le README pour les étapes.",
    },
    "sync.received_from": {
        "en": "Received from %@",
        "zh-Hans": "已接收来自 %@ 的内容",
        "zh-Hant": "已接收來自 %@ 的內容",
        "ja": "%@ から受信しました",
        "ko": "%@(으)로부터 수신함",
        "fr": "Reçu de %@",
    },
    "about.title": {
        "en": "About SkyPaste",
        "zh-Hans": "关于 SkyPaste",
        "zh-Hant": "關於 SkyPaste",
        "ja": "SkyPaste について",
        "ko": "SkyPaste 정보",
        "fr": "À propos de SkyPaste",
    },
    "about.subtitle": {
        "en": "MIT license · Built for Windows 10 and 11",
        "zh-Hans": "MIT 许可证 · 为 Windows 10/11 打造",
        "zh-Hant": "MIT 授權 · 為 Windows 10/11 打造",
        "ja": "MIT ライセンス · Windows 10/11 向け",
        "ko": "MIT 라이선스 · Windows 10/11용",
        "fr": "Licence MIT · Conçu pour Windows 10 et 11",
    },
    "about.open_license": {
        "en": "View License",
        "zh-Hans": "查看许可证",
        "zh-Hant": "查看授權",
        "ja": "ライセンスを表示",
        "ko": "라이선스 보기",
        "fr": "Voir la licence",
    },
    "paste.foreground_failed": {
        "en": "Copied. The previous window could not be focused automatically — press Ctrl+V to paste.",
        "zh-Hans": "已复制。无法自动切回之前的窗口，请手动按 Ctrl+V 粘贴。",
        "zh-Hant": "已複製。無法自動切回之前的視窗，請手動按 Ctrl+V 貼上。",
        "ja": "コピーしました。前のウィンドウに自動で切り替えできませんでした。Ctrl+V で貼り付けてください。",
        "ko": "복사했습니다. 이전 창으로 자동 전환하지 못했습니다. Ctrl+V로 붙여넣으세요.",
        "fr": "Copié. Impossible de revenir automatiquement à la fenêtre précédente — collez avec Ctrl+V.",
    },
    "settings.lan_sync_firewall_hint": {
        "en": "If Windows Firewall asks for permission, choose \"Allow\" — otherwise your phone cannot send clipboard content to this PC.",
        "zh-Hans": "如果 Windows 防火墙弹出权限询问，请选择「允许访问」，否则手机将无法推送剪贴板内容到这台电脑。",
        "zh-Hant": "如果 Windows 防火牆彈出權限詢問，請選擇「允許存取」，否則手機將無法傳送剪貼簿內容到這台電腦。",
        "ja": "Windows ファイアウォールの確認が表示されたら「許可」を選んでください。許可しないとスマホからこの PC に送信できません。",
        "ko": "Windows 방화벽 권한을 묻는 창이 뜨면 \"허용\"을 선택하세요. 허용하지 않으면 휴대폰에서 이 PC로 보낼 수 없습니다.",
        "fr": "Si le pare-feu Windows demande l'autorisation, choisissez « Autoriser » — sinon votre téléphone ne pourra pas envoyer de contenu vers ce PC.",
    },
    "settings.panel_position": {
        "en": "Panel position",
        "zh-Hans": "面板位置",
        "zh-Hant": "面板位置",
        "ja": "パネル位置",
        "ko": "패널 위치",
        "fr": "Position du panneau",
    },
    "settings.lan_sync_qr": {
        "en": "Web clipboard QR code",
        "zh-Hans": "手机网页剪贴板二维码",
        "zh-Hant": "手機網頁剪貼簿二維碼",
        "ja": "Web クリップボード QR コード",
        "ko": "웹 클립보드 QR 코드",
        "fr": "QR code du presse-papiers web",
    },
    "settings.lan_sync_qr_hint": {
        "en": "Scan with your phone camera to open the web clipboard (no app needed).",
        "zh-Hans": "用手机相机扫码打开网页剪贴板，无需安装任何应用。",
        "zh-Hant": "用手機相機掃碼開啟網頁剪貼簿，無需安裝任何應用。",
        "ja": "スマホのカメラで読み取ると Web クリップボードが開きます（アプリ不要）。",
        "ko": "휴대폰 카메라로 스캔하면 웹 클립보드가 열립니다(앱 불필요).",
        "fr": "Scannez avec l'appareil photo du téléphone pour ouvrir le presse-papiers web (aucune app requise).",
    },
    "panel_position.center": {
        "en": "Centered on screen",
        "zh-Hans": "屏幕居中",
        "zh-Hant": "螢幕置中",
        "ja": "画面中央",
        "ko": "화면 중앙",
        "fr": "Centré à l'écran",
    },
    "panel_position.cursor": {
        "en": "Follow cursor",
        "zh-Hans": "跟随鼠标",
        "zh-Hant": "跟隨游標",
        "ja": "カーソルに追従",
        "ko": "커서 따라가기",
        "fr": "Suivre le curseur",
    },
    "hotkey.register_failed": {
        "en": "This shortcut is taken by another app — pick a different combination.",
        "zh-Hans": "该快捷键已被其他程序占用，请更换组合。",
        "zh-Hant": "該快捷鍵已被其他程式佔用，請更換組合。",
        "ja": "このショートカットは他のアプリで使用中です。別の組み合わせを選んでください。",
        "ko": "이 단축키는 다른 프로그램이 사용 중입니다. 다른 조합을 선택하세요.",
        "fr": "Ce raccourci est déjà utilisé par une autre application — choisissez une autre combinaison.",
    },
    "panel_position.remember": {
        "en": "Remember last position",
        "zh-Hans": "记住上次位置",
        "zh-Hant": "記住上次位置",
        "ja": "前回の位置を記憶",
        "ko": "마지막 위치 기억",
        "fr": "Mémoriser la dernière position",
    },
}

LINE_RE = re.compile(r'^"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')


def unescape(s: str) -> str:
    return (
        s.replace("\\\"", '"')
        .replace("\\n", "\n")
        .replace("\\t", "\t")
        .replace("\\\\", "\\")
    )


def escape_xml(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def parse_strings(path: str) -> dict:
    out = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("//"):
                continue
            m = LINE_RE.match(line)
            if not m:
                continue
            out[unescape(m.group(1))] = unescape(m.group(2))
    return out


def build_table(lang: str) -> dict:
    table = parse_strings(os.path.join(STRINGS_DIR, f"{lang}.lproj", "Localizable.strings"))
    renamed = {}
    for k, v in table.items():
        nk = RENAMES.get(k, k)
        if nk is None:
            continue
        renamed[nk] = v
    for key, per_lang in OVERRIDES.items():
        if lang in per_lang:
            renamed[key] = per_lang[lang]
    for key, per_lang in NEW_KEYS.items():
        renamed[key] = per_lang[lang]
    return renamed


def write_resx(table: dict, path: str) -> None:
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<root>",
    ]
    for key in table:
        lines.append(f'  <data name="{escape_xml(key)}" xml:space="preserve"><value>{escape_xml(table[key])}</value></data>')
    lines.append("</root>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    reference = build_table("en")
    for lang in LANGS:
        table = build_table(lang)
        if lang == "en":
            path = os.path.join(OUT_DIR, "Strings.resx")
        else:
            path = os.path.join(OUT_DIR, f"Strings.{lang}.resx")
        write_resx(table, path)
        missing = set(reference) - set(table)
        extra = set(table) - set(reference)
        print(f"{lang}: {len(table)} keys -> {path}" + (f" missing={sorted(missing)}" if missing else "") + (f" extra={sorted(extra)}" if extra else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
