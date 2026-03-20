# App Store Preparation

SkyPaste can be submitted to the Mac App Store with the current Xcode project, but it should stay on the minimum required capabilities.

## What to enable in Xcode

In `Signing & Capabilities` for the `SkyPaste` target:

- Enable `App Sandbox`
- Use your Apple Developer Team
- Keep the app category set to `Utilities`

## Recommended sandbox settings

Keep the following unset unless you add a feature that truly needs them:

- Network: no incoming or outgoing connections
- Hardware: no camera, audio input, USB, printing, or Bluetooth
- App Data: no contacts, location, or calendar
- File Access: leave the file access rows at `None`

SkyPaste stores its clipboard database inside the app container, so it does not need broad file-system access for the current feature set.

## Review-sensitive behavior

- Keep automatic paste disabled by default in the App Store build
- Leave `launch at login` optional
- Avoid temporary exception entitlements unless a future feature absolutely requires them

## Build configuration notes

The Release configuration already sets the `APP_STORE_BUILD` compilation condition, which makes the app default to copy-only behavior instead of auto-paste.

## Before submitting

1. Archive the app from Xcode
2. Check the archive in Organizer
3. Upload to App Store Connect
4. Fill out screenshots, privacy details, review notes, and category
