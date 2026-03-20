# App Store Preparation

SkyPaste can be prepared for Mac App Store distribution, but it still needs a real Xcode-based signing and archive workflow.

## What the repo already does

- Stores local data in `Application Support`
- Avoids hard-coded filesystem paths
- Keeps login item support behind `SMAppService`
- Makes automatic paste optional via `settings.autoPasteEnabled`
- Provides an App Sandbox entitlement file at `SkyPaste.entitlements`

## What still needs manual Xcode work

1. Open the package in Xcode or create an Xcode project from this package
2. Add `App Sandbox` in `Signing & Capabilities`
3. Select your Apple Developer Team
4. Use a Mac App Store distribution profile
5. Archive from Xcode
6. Upload the archive to App Store Connect

## Recommended capabilities

- `App Sandbox`
- No network capability unless you add cloud sync
- No file access entitlement unless you add explicit file import/export

## Recommended settings for App Store review

- Keep `auto paste after copy` disabled by default in the App Store build
- Keep login start optional
- Avoid adding temporary exception entitlements unless absolutely required

## Local test build

To make local packaging closer to App Store behavior:

```bash
APP_STORE_BUILD=1 ./build_app.sh
```

That flips the default for `autoPasteEnabled` to `false` and signs the app with the sandbox entitlement file.
