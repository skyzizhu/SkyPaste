using System.Windows;
using System.Windows.Interop;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Port of macOS AppCoordinator: owns the main panel, tray popover, settings,
/// statistics, debug and preview windows; performs "copy" and "paste back".
/// </summary>
public sealed class AppCoordinator
{
    private readonly App _app;
    private MainWindow? _mainWindow;
    private TrayPopoverWindow? _trayPopover;
    private SettingsWindow? _settingsWindow;
    private StatisticsWindow? _statisticsWindow;
    private DebugWindow? _debugWindow;
    private IntPtr _previousForegroundWindow;

    public AppCoordinator(App app)
    {
        _app = app;
        _app.Store.ItemsChanged += OnItemsChanged;
        _app.Store.SetSearchQuery(string.Empty);
    }

    private void OnItemsChanged()
    {
        _mainWindow?.OnStoreChanged();
        _trayPopover?.OnStoreChanged();
    }

    // ---- main panel ---------------------------------------------------------

    public void PreloadMainWindow()
    {
        EnsureMainWindow();
        _mainWindow!.Hide();
    }

    private void EnsureMainWindow()
    {
        if (_mainWindow is null)
        {
            _mainWindow = new MainWindow(_app);
        }
    }

    public void TogglePanel()
    {
        if (_mainWindow is { Visibility: Visibility.Visible })
        {
            ClosePanel();
        }
        else
        {
            ShowPanel();
        }
    }

    public void ShowPanel()
    {
        EnsureMainWindow();
        _mainWindow!.ShowPanel();
    }

    public void ClosePanel()
    {
        _mainWindow?.Hide();
    }

    /// <summary>Called by windows right before they appear (mac captureFrontApp).</summary>
    public void CaptureForeground() => _previousForegroundWindow = PasteBackService.CaptureForeground();

    /// <summary>Renders the visible main panel to a PNG (CI --uitesting screenshots).</summary>
    public void CaptureMainWindowScreenshot(string path)
    {
        var window = _mainWindow;
        if (window is null || !window.IsVisible)
        {
            return;
        }
        try
        {
            var width = (int)window.ActualWidth;
            var height = (int)window.ActualHeight;
            if (width <= 0 || height <= 0)
            {
                return;
            }
            var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(
                width, height, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
            bitmap.Render(window);
            var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
            encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
            using var stream = System.IO.File.Create(path);
            encoder.Save(stream);
        }
        catch (Exception)
        {
        }
    }

    // ---- copy / paste ---------------------------------------------------------

    /// <summary>Copy an item to the clipboard without closing anything.</summary>
    public void CopyOnly(ClipboardItem item)
    {
        var full = _app.Store.RestoreFullResolutionItem(item);
        _app.Monitor.SuppressNextCapture();
        try
        {
            ClipboardWriter.Write(full);
        }
        catch (Exception)
        {
        }
        _app.Toast.Show(L10n.T("menu.copy_success"));
    }

    /// <summary>Primary action: copy, close panel, restore previous app, send Ctrl+V.</summary>
    public void Paste(ClipboardItem item)
    {
        var full = _app.Store.RestoreFullResolutionItem(item);
        _app.Monitor.SuppressNextCapture();
        try
        {
            ClipboardWriter.Write(full);
        }
        catch (Exception)
        {
        }
        ClosePanel();

        // Focus + SendInput can block briefly and must not freeze the UI thread;
        // elevated target windows may refuse SetForegroundWindow -> degrade to
        // "copied only" with a hint instead of pasting into the wrong window.
        var previousWindow = _previousForegroundWindow;
        Task.Run(() =>
        {
            var pasted = PasteBackService.RestoreAndPaste(previousWindow);
            if (!pasted)
            {
                _app.Dispatcher.BeginInvoke(() =>
                    _app.Toast.Show(L10n.T("paste.foreground_failed")));
            }
        });
    }

    // ---- tray popover ----------------------------------------------------------

    public void ToggleTrayPopover()
    {
        if (_trayPopover is { Visibility: Visibility.Visible })
        {
            _trayPopover.Close();
            _trayPopover = null;
        }
        else
        {
            _trayPopover = new TrayPopoverWindow(_app);
            _trayPopover.Show();
            _trayPopover.Activate();
        }
    }

    // ---- secondary windows -------------------------------------------------------

    public void ShowSettings()
    {
        if (_settingsWindow is { Visibility: Visibility.Visible })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_app);
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void ShowStatistics()
    {
        if (_statisticsWindow is { Visibility: Visibility.Visible })
        {
            _statisticsWindow.Activate();
            return;
        }
        _statisticsWindow = new StatisticsWindow(_app);
        _statisticsWindow.Show();
        _statisticsWindow.Activate();
    }

    public void ShowDebug()
    {
        if (_debugWindow is { Visibility: Visibility.Visible })
        {
            _debugWindow.Activate();
            return;
        }
        _debugWindow = new DebugWindow(_app);
        _debugWindow.Show();
        _debugWindow.Activate();
    }

    // ---- previews -------------------------------------------------------------------

    public void OpenPreview(ClipboardItem item)
    {
        switch (item.Content.Kind)
        {
            case ClipboardContentKind.Image:
                OpenImagePreview(item);
                break;
            case ClipboardContentKind.Text:
                OpenTextPreview(item);
                break;
            case ClipboardContentKind.FileRefs:
                OpenFilePreview(item);
                break;
        }
    }

    private void OpenImagePreview(ClipboardItem item)
    {
        var full = _app.Store.RestoreFullResolutionItem(item);
        var window = new ImagePreviewWindow(_app, full);
        window.Show();
        window.Activate();
    }

    private void OpenTextPreview(ClipboardItem item)
    {
        var window = new TextPreviewWindow(_app, item);
        window.Show();
        window.Activate();
    }

    private void OpenFilePreview(ClipboardItem item)
    {
        var window = new FilePreviewWindow(_app, item);
        window.Show();
        window.Activate();
    }

    // ---- file actions ------------------------------------------------------------------

    public void OpenPaths(IReadOnlyList<string> paths)
    {
        foreach (var path in paths)
        {
            try
            {
                if (System.IO.Directory.Exists(path))
                {
                    ProcessStart("explorer.exe", $"\"{path}\"");
                }
                else if (System.IO.File.Exists(path))
                {
                    ProcessStart(path, string.Empty, useShellExecute: true);
                }
                else
                {
                    _app.Toast.Show(L10n.Format("open.missing_item_message", path));
                }
            }
            catch (Exception)
            {
            }
        }
    }

    public void RevealInExplorer(IReadOnlyList<string> paths)
    {
        foreach (var path in paths)
        {
            try
            {
                if (System.IO.File.Exists(path) || System.IO.Directory.Exists(path))
                {
                    ProcessStart("explorer.exe", $"/select,\"{path}\"");
                }
                else
                {
                    _app.Toast.Show(L10n.Format("open.missing_item_message", path));
                }
            }
            catch (Exception)
            {
            }
        }
    }

    public void CopyPaths(IReadOnlyList<string> paths)
    {
        try
        {
            Clipboard.SetText(string.Join(Environment.NewLine, paths));
        }
        catch (Exception)
        {
        }
        _app.Toast.Show(L10n.T("menu.copy_success"));
    }

    public void OpenInBrowser(Uri? url)
    {
        if (url is null)
        {
            return;
        }
        try
        {
            ProcessStart(url.ToString(), string.Empty, useShellExecute: true);
        }
        catch (Exception)
        {
        }
    }

    public void OpenEmail(Uri? mailto)
    {
        if (mailto is null)
        {
            return;
        }
        try
        {
            ProcessStart(mailto.ToString(), string.Empty, useShellExecute: true);
        }
        catch (Exception)
        {
        }
    }

    private static void ProcessStart(string fileName, string arguments, bool useShellExecute = false)
    {
        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = useShellExecute,
        };
        System.Diagnostics.Process.Start(startInfo);
    }
}
