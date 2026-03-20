# SkyPaste

A macOS clipboard manager inspired by PasteNow.

## Implemented

- Clipboard history for text, images, and file URLs
- Search/filter across clipboard history
- Global hotkey to toggle panel (customizable)
- Keyboard navigation: `Up/Down` select, `Enter` paste, `Esc` close
- Quick paste shortcuts: `Cmd+1` ... `Cmd+9`
- Double-click to paste
- Menu bar item with `Open` / `Preferences` / `Quit`
- Keeps latest N unique clipboard records (customizable, default 200)
- Persistent history storage with SQLite (`~/Library/Application Support/SkyPaste/history.sqlite`)
- Ignore apps list (bundle IDs) to skip clipboard capture in sensitive apps
- Launch at login toggle (for packaged app)

## Run (dev)

```bash
cd /Users/fushan/Desktop/wenxiaowei-1/mac-pastenow-clone
swift run
```

## Build App Bundle (.app)

```bash
cd /Users/fushan/Desktop/wenxiaowei-1/mac-pastenow-clone
./build_app.sh
```

Output path:

`/Users/fushan/Desktop/wenxiaowei-1/mac-pastenow-clone/dist/SkyPaste.app`

## Settings

Open `Preferences` from the menu bar icon.

- Hotkey key + modifiers
- History max records
- Ignored apps (comma/newline-separated bundle IDs)

## Permissions

To support automatic paste into the previous app, macOS may ask for Accessibility permission:

- `System Settings` -> `Privacy & Security` -> `Accessibility`
- Enable your terminal (or the built app) running this app

## Notes

- Sync, tags, and encryption are not implemented in this version.
