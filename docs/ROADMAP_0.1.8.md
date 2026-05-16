# SkyPaste 0.1.8 Plan

## Goal

Make SkyPaste handle Finder-style clipboard content more naturally, so copied files and folders feel like first-class clipboard items instead of generic file URL data.

Core direction for `0.1.8`:

- Recognize copied files more clearly
- Recognize copied folders more clearly
- Let users open copied items directly from history
- Gracefully handle missing or moved paths

## Must Have

### 1. File Copy Recognition

Add clear recognition for copied files.

Initial scope:

- Detect single-file clipboard items
- Distinguish files from generic text or URLs
- Show better title and subtitle metadata for files
- Support opening files by double-clicking the list item

Expected value:

- Makes Finder copy workflows feel native
- Reduces friction when reusing copied files from history

Acceptance:

- A copied file appears as a file item in the list
- Double-click opens the file with the system default app
- Right-click menu includes an `Open File` action

### 2. Folder Copy Recognition

Add clear recognition for copied folders.

Initial scope:

- Detect copied folders
- Display folder-specific title and subtitle copy
- Support opening folders directly from history

Expected value:

- Improves workflows for design assets, project folders, and document collections
- Makes clipboard history more useful for Finder-heavy users

Acceptance:

- A copied folder appears as a folder item in the list
- Double-click opens the folder in Finder
- Right-click menu includes an `Open Folder` action

### 3. Missing Path Handling

Handle deleted or moved files and folders gracefully.

Initial scope:

- Check path existence before opening
- Show a clear not-found prompt when the original path is no longer valid
- Keep the item visible in history even if the path is broken

Expected value:

- Prevents confusing no-op behavior
- Makes file and folder history feel dependable

Acceptance:

- Missing files show a `File Not Found` style warning
- Missing folders show a `Folder Not Found` style warning
- Existing items still open normally

## Nice To Have

### 4. Multi-Item Finder Copies

Improve handling when users copy multiple files or folders at once.

Possible scope:

- Better group titles for multiple files
- Better group titles for multiple folders
- Open all copied items together when appropriate
- Warn clearly if only part of the selection still exists

### 5. Finder-Oriented Search Keywords

Make file and folder history easier to find through search.

Possible scope:

- Search aliases for `file`, `folder`, `directory`
- Chinese keyword coverage for `文件`, `文件夹`, `目录`
- Better matching on filenames and parent paths

## Defer For Now

Not recommended for this version:

- OCR for images
- Smart paste transformations
- Source app filtering
- Large privacy rule systems

Reason:

- `0.1.8` should stay focused on finishing file and folder workflows well
- These other ideas can come next after Finder clipboard support is stable

## Recommended Development Order

### Phase 1

- File copy recognition
- Folder copy recognition

### Phase 2

- Double-click open behavior
- Right-click open actions

### Phase 3

- Missing path alerts
- Multi-item polish

## Release Positioning

If `0.1.8` lands well, the release message can focus on:

- Better support for copied files
- Better support for copied folders
- Double-click to open from clipboard history
- Clear feedback when the original path no longer exists

Suggested theme:

`Clipboard history that works better with Finder`

## Notes

- Keep the interaction consistent between the main panel and menu bar panel
- Preserve existing image preview and text preview behavior
- Prefer lightweight, system-native open behavior over custom file preview UI
