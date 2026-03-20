# Releasing SkyPaste

SkyPaste is maintained as an Xcode app project now, so releases are driven from the Xcode target settings.

## Versioning

Update these values in `skypaste.xcodeproj` before every release:

- `MARKETING_VERSION` for the public app version
- `CURRENT_PROJECT_VERSION` for the build number

A simple pattern is:

- `MARKETING_VERSION`: `0.1.2`, `0.1.3`, ...
- `CURRENT_PROJECT_VERSION`: increment by 1 for each archive build

## Release Checklist

1. Update the version and build number in Xcode
2. Verify `README.md` and screenshots are current
3. Build and run the app locally
4. Archive from Xcode with `Product -> Archive`
5. For GitHub releases, export or zip the built `.app`
6. Commit the release changes
7. Tag the release and push the tag
8. Publish the GitHub Release asset

## GitHub Release Notes

Recommended release note format:

```text
## SkyPaste <version>

English
- Summary of notable changes

中文
- 本版本的主要更新
```

## Notes

- The Xcode project is the source of truth for build settings
- The App Store build uses the `APP_STORE_BUILD` compilation condition
- Keep screenshots and README in sync with the current UI
