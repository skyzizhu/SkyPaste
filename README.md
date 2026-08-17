# SkyPaste - macOS Clipboard Manager with History, Search, Sync, Files and Images

<p align="center">
  <img src="skypaste/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" alt="SkyPaste macOS clipboard manager app icon" width="120">
</p>

<p align="center">
  <strong>A lightweight clipboard history manager for macOS.</strong><br>
  Save, search, preview, organize, and sync copied text, links, images, files, folders, code, and email addresses.
</p>

<p align="center">
  <a href="README.zh-CN.md">中文</a> | English
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/skypaste-clipboard-manager/id6760884520?mt=12">Download on the Mac App Store</a>
</p>

SkyPaste is a simple and fast macOS clipboard manager built for people who copy and paste all day. It records clipboard history, keeps content searchable, groups items by type, supports menu bar quick access, and can sync SkyPaste clipboard content across devices with iCloud.

## Keywords

macOS clipboard manager, clipboard history, clipboard search, clipboard sync, iCloud clipboard, menu bar clipboard app, copy paste tool, paste manager, image clipboard, file clipboard, folder clipboard, URL history, email clipboard, productivity app for Mac.

## What's New

- Added drag-and-drop for images, files, and folders: drag items from the menu bar or main panel straight into Finder, Mail, and other apps.
- Finder-style drag previews with stacked icons, an item-count badge, and a dimmed source row while dragging.
- Dragged images always use the original full-resolution data instead of the list thumbnail.
- Shows an alert when a dragged file or folder no longer exists on disk.
- Refactored the app into a dedicated app coordinator and separate image, text, and file preview windows.

## Screenshots

### Menu Bar Clipboard History

![SkyPaste menu bar clipboard history](docs/screen/screen_2.png)

### Main Clipboard Panel

![SkyPaste main clipboard panel](docs/screen/screen_3.png)

### Preferences

![SkyPaste preferences](docs/screen/screen_4.png)

### Overview

![SkyPaste overview](docs/screen/screen_1.png)

## Features

- Clipboard history for text, links, images, files, folders, code, and email addresses.
- Fast menu bar popover for quick clipboard access.
- Full clipboard panel with search, filters, source app filtering, and day-based history groups.
- Filters for All, Text, Image, Files, Folders, Code, URL, Email, and Favorites.
- Email recognition with a dedicated Email category and Send Email action.
- URL recognition with Open in Browser action.
- File and folder recognition with preview, copy path, Finder reveal, and open actions.
- Drag images, files, and folders out of the list into Finder and other apps.
- Image preview with zoom and pan support.
- Favorites that remain available even when regular history is trimmed.
- Batch selection, batch delete, and batch favorite actions.
- Source app badges for locally copied content.
- iCloud sync for SkyPaste clipboard content across devices.
- iPhone-to-Mac copied content sync when using the same Apple account.
- Privacy content filtering option for sensitive clipboard text.
- Ignore apps by app name or bundle ID.
- Customizable global hotkey.
- Keyboard shortcuts: `Cmd+C`, `Enter`, and `Cmd+1...9`.
- Appearance modes: Follow System, Light Mode, and Dark Mode.
- Multi-language UI: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, and French.
- Local SQLite persistence.
- Image memory optimization with lazy thumbnails and on-demand full image restore.

## Local Storage

SkyPaste stores clipboard history locally in SQLite:

```text
~/Library/Application Support/SkyPaste/history.sqlite
```

Data stays local by default. iCloud sync is optional and can be configured in Preferences.

## Open in Xcode

SkyPaste uses the Xcode project at `skypaste.xcodeproj`.

```text
open skypaste.xcodeproj
```

Run with `Product -> Run`, or create a release build with `Product -> Archive`.

For App Store submission, use Xcode Archive and App Store Connect.

## Release and App Store Notes

- Release checklist: [docs/RELEASING.md](docs/RELEASING.md)
- App Store checklist: [docs/APP_STORE.md](docs/APP_STORE.md)
- Metadata checklist: [docs/APP_STORE_CHECKLIST.md](docs/APP_STORE_CHECKLIST.md)
- Privacy policy template: [docs/PRIVACY_POLICY.md](docs/PRIVACY_POLICY.md)

## Permissions

To support paste back into the previous app, macOS may request Accessibility permission:

```text
System Settings -> Privacy & Security -> Accessibility
```

Enable the packaged SkyPaste app, or the terminal/Xcode app used to run it during development.

## License

[MIT](LICENSE)
