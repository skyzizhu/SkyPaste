#!/usr/bin/env python3
"""Fixes from first real-device test round:
1. Double-click opened preview AND copied: the second MouseUp re-scheduled
   the pending copy. Now double-click suppresses the next click dispatch.
2. Preferences 'sometimes' not opening: Activate can be denied by the
   foreground-lock; flash Topmost to force the window to the front.
3. Blank images: a failed thumbnail (clipboard locked at capture moment)
   was cached as empty FOREVER. Failures are no longer cached, and capture
   diagnostics (format + byte count) go to the ui log."""

def patch(path, old, new):
    s = open(path, encoding="utf-8").read()
    assert old in s, (path, old[:70])
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))

changes = []

# ---- 1) double-click must not also copy ----
p = "src/SkyPaste/Views/Controls/ClipboardListPanel.xaml.cs"
patch(p,
"    private bool _suppressSearchCallback;",
"    private bool _suppressSearchCallback;\n"
+ "    private bool _suppressClick;")
patch(p,
"""        border.MouseUp += (_, e) =>
        {
            if (e.ChangedButton == MouseButton.Left && !_batchMode)
            {
                SchedulePendingPrimaryAction(item);
            }
        };""",
"""        border.MouseUp += (_, e) =>
        {
            if (e.ChangedButton == MouseButton.Left && !_batchMode)
            {
                if (_suppressClick)
                {
                    // Second release of a double-click: preview already opened.
                    _suppressClick = false;
                    return;
                }
                SchedulePendingPrimaryAction(item);
            }
        };""")
patch(p,
"""            if (e.ClickCount == 2 && !_batchMode)
            {
                CancelPendingPrimaryAction();
                _app.Coordinator.OpenPreview(item);
            }""",
"""            if (e.ClickCount == 2 && !_batchMode)
            {
                CancelPendingPrimaryAction();
                _suppressClick = true;
                _app.Coordinator.OpenPreview(item);
            }""")
changes.append(("ClipboardListPanel", "double-click no longer also copies"))

# ---- 2) force tool windows to the front ----
p = "src/SkyPaste/AppCoordinator.cs"
patch(p,
"""        _app.UiLog("ShowSettings: creating window");
        _settingsWindow = new SettingsWindow(_app) { Owner = ToolOwner };
        _app.UiLog("ShowSettings: ctor ok, showing");
        _settingsWindow.Show();
        _settingsWindow.Activate();
        _app.UiLog($"ShowSettings: shown, visibility={_settingsWindow.Visibility}, isLoaded={_settingsWindow.IsLoaded}");""",
"""        _app.UiLog("ShowSettings: creating window");
        _settingsWindow = new SettingsWindow(_app) { Owner = ToolOwner };
        _app.UiLog("ShowSettings: ctor ok, showing");
        _settingsWindow.Show();
        _settingsWindow.Activate();
        ForceToFront(_settingsWindow);
        _app.UiLog($"ShowSettings: shown, visibility={_settingsWindow.Visibility}, isLoaded={_settingsWindow.IsLoaded}");""")

patch(p,
"""        _statisticsWindow = new StatisticsWindow(_app) { Owner = ToolOwner };
        _statisticsWindow.Show();
        _statisticsWindow.Activate();""",
"""        _statisticsWindow = new StatisticsWindow(_app) { Owner = ToolOwner };
        _statisticsWindow.Show();
        _statisticsWindow.Activate();
        ForceToFront(_statisticsWindow);""")

patch(p,
"""        _debugWindow = new DebugWindow(_app) { Owner = ToolOwner };
        _debugWindow.Show();
        _debugWindow.Activate();""",
"""        _debugWindow = new DebugWindow(_app) { Owner = ToolOwner };
        _debugWindow.Show();
        _debugWindow.Activate();
        ForceToFront(_debugWindow);""")

patch(p,
"""    private System.Windows.Window? ToolOwner =>""",
"""    /// <summary>
    /// Activate() alone can be denied by the Windows foreground lock when the
    /// caller is not the foreground process; a one-frame Topmost flash wins.
    /// </summary>
    private static void ForceToFront(System.Windows.Window window)
    {
        try
        {
            window.Topmost = true;
            window.Topmost = false;
        }
        catch (Exception)
        {
        }
    }

    private System.Windows.Window? ToolOwner =>""")
changes.append(("AppCoordinator", "ForceToFront for settings/statistics/debug"))

# ---- 3) thumbnails: never cache failures -------------------------------
p = "src/SkyPaste/Services/ImageServices.cs"
patch(p,
"""    /// <summary>Returns PNG thumbnail bytes for an image item (or null when unavailable).</summary>
    public byte[]? GetImageThumbnail(ClipboardItem item)
    {
        if (item.Content.Kind != ClipboardContentKind.Image)
        {
            return null;
        }
        var key = item.Id + "#image-data";
        return _cache.GetOrAdd(key, _ =>
            ImageOptimizerService.CreateThumbnail(item.Content.ImageData ?? Array.Empty<byte>(), RowMaxPixelSize)
            ?? Array.Empty<byte>()) is { Length: > 0 } bytes ? bytes : null;
    }

    /// <summary>Returns PNG thumbnail bytes for a single image file on disk.</summary>
    public byte[]? GetFileThumbnail(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        return _cache.GetOrAdd(path.ToLowerInvariant() + "#160", _ =>
            ImageOptimizerService.CreateThumbnail(LoadFileBytes(path), RowMaxPixelSize)
            ?? Array.Empty<byte>()) is { Length: > 0 } bytes ? bytes : null;
    }""",
"""    /// <summary>Returns PNG thumbnail bytes for an image item (or null when unavailable).</summary>
    public byte[]? GetImageThumbnail(ClipboardItem item)
    {
        if (item.Content.Kind != ClipboardContentKind.Image)
        {
            return null;
        }
        var key = item.Id + "#image-data";
        if (_cache.TryGetValue(key, out var cached) && cached.Length > 0)
        {
            return cached;
        }
        var bytes = ImageOptimizerService.CreateThumbnail(
            item.Content.ImageData ?? Array.Empty<byte>(), RowMaxPixelSize);
        // Never cache failures: a transient clipboard lock at capture time must
        // not blank the row forever.
        if (bytes is { Length: > 0 })
        {
            _cache[key] = bytes;
            return bytes;
        }
        return null;
    }

    /// <summary>Returns PNG thumbnail bytes for a single image file on disk.</summary>
    public byte[]? GetFileThumbnail(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        var key = path.ToLowerInvariant() + "#160";
        if (_cache.TryGetValue(key, out var cached) && cached.Length > 0)
        {
            return cached;
        }
        var bytes = ImageOptimizerService.CreateThumbnail(LoadFileBytes(path), RowMaxPixelSize);
        if (bytes is { Length: > 0 })
        {
            _cache[key] = bytes;
            return bytes;
        }
        return null;
    }""")
changes.append(("ThumbnailProvider", "failures not cached"))

# ---- 4) capture diagnostics for image decoding -------------------------
p = "src/SkyPaste/Services/ClipboardDecoder.cs"
patch(p,
"""        // 2. Images (PNG raw bytes first, then DIB).
        try
        {
            var imageData = TryReadImage();
            if (imageData is { Length: > 0 })
            {""",
"""        // 2. Images (PNG raw bytes first, then DIB).
        try
        {
            var imageData = TryReadImage();
            SkyPaste.App.UiLog($"decode image: bytes={imageData?.LongLength ?? 0}");
            if (imageData is { Length: > 0 })
            {""")
patch(p,
"""        // 3. Text (URLs and emails are classified downstream).
        try
        {""",
"""        SkyPaste.App.UiLog("decode: files/image/text all empty or unreadable");
        // 3. Text (URLs and emails are classified downstream).
        try
        {""")
changes.append(("ClipboardDecoder", "capture diagnostics"))

print("changes:")
for f, what in changes:
    print(f"  {f}: {what}")
