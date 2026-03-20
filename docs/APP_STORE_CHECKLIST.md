# App Store Submission Checklist

Use this checklist when preparing a SkyPaste App Store submission.

## Required metadata

- App name
- Subtitle
- Description
- Keywords
- Support URL
- Privacy Policy URL
- Category: Utilities
- Age rating
- App privacy details
- Review notes
- Version number
- Build number

## Screenshot checklist

- Capture the menu bar popover
- Capture the main panel with representative clipboard history
- Capture the preferences window
- Use clean screenshots without sensitive clipboard content
- Keep screenshots aligned with the current UI

## Review notes template

Paste something like this into App Store Connect review notes:

```text
SkyPaste is a menu bar clipboard manager.

What to test:
- Open the menu bar popover and review clipboard history
- Use the main panel to search, filter, and manage items
- Copy an item from the list to put it back on the clipboard

Notes:
- Clipboard data is stored locally on the device
- Cloud sync is not enabled
- Automatic paste is disabled by default in the App Store build
- If you need to test paste-back behavior, enable Accessibility permission in System Settings
```

## Final checks before upload

1. Confirm the archive is signed with your App Store distribution identity
2. Confirm App Sandbox is enabled
3. Confirm the build number was incremented
4. Confirm the privacy policy URL is reachable publicly
5. Confirm the screenshots match the current app
