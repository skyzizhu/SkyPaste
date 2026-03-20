# Releasing SkyPaste

SkyPaste follows semantic versioning:

- `MAJOR`: breaking changes
- `MINOR`: backward-compatible features
- `PATCH`: backward-compatible fixes

Current version source of truth:

```text
VERSION
```

## Release Checklist

1. Update `VERSION`
2. Review `README.md` and screenshots
3. Build the app
4. Zip the app bundle
5. Commit the release changes
6. Create and push the release tag
7. Publish a GitHub Release and upload the zip asset

## Commands

Build the app:

```bash
cd SkyPaste
./build_app.sh
```

Create the downloadable archive:

```bash
cd SkyPaste
VERSION=$(cat VERSION)
ditto -c -k --sequesterRsrc --keepParent "dist/SkyPaste.app" "dist/SkyPaste-${VERSION}-macos.zip"
```

Commit and tag:

```bash
cd SkyPaste
git add .
git commit -m "Release v$(cat VERSION)"
git tag -a "v$(cat VERSION)" -m "SkyPaste $(cat VERSION)"
git push origin main
git push origin "v$(cat VERSION)"
```

## GitHub Release

Create a new release from the tag:

- Release title: `SkyPaste <version>`
- Asset: `dist/SkyPaste-<version>-macos.zip`

Recommended release notes format:

```text
## SkyPaste <version>

English
- Summary of notable changes

中文
- 本版本的主要更新
```

## Notes

- `build_app.sh` reads the version from `VERSION`
- The packaged app is unsigned with an ad-hoc signature
- If you ever expose a GitHub token in screenshots or clipboard history, revoke it immediately before publishing
