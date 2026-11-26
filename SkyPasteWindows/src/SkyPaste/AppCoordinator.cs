using System.Windows;
using System.Windows.Interop;
using System.Runtime.InteropServices;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Interop;
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
    public void CaptureForeground()
    {
        var window = PasteBackService.CaptureForeground();
        if (window != IntPtr.Zero)
        {
            NativeMethods.GetWindowThreadProcessId(window, out var processId);
            if (processId != 0 && processId != Environment.ProcessId)
            {
                _previousForegroundWindow = window;
            }
        }
    }


    /// <summary>Renders a window to a PNG (CI --uitesting screenshots).</summary>
    public void CaptureWindowScreenshot(System.Windows.Window window, string path)
    {
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

    public System.Windows.Window? SettingsWindowView => _settingsWindow;
    public System.Windows.Window? StatisticsWindowView => _statisticsWindow;
    public System.Windows.Window? MainWindowView => _mainWindow;

    // ---- copy / paste ---------------------------------------------------------

    /// <summary>Copy an item to the clipboard without closing anything.</summary>
    public void CopyOnly(ClipboardItem item)
    {
        if (TryWriteClipboard(() => ClipboardWriter.Write(_app.Store.RestoreFullResolutionItem(item))))
        {
            _app.Toast.Show(L10n.T("menu.copy_success"));
        }
    }

    public void Share(Window owner, ClipboardItem item)
    {
        try
        {
            var full = _app.Store.RestoreFullResolutionItem(item);
            if (owner is TrayPopoverWindow popover)
            {
                popover.ShowSystemShare(() => WindowsShareService.Show(owner, full));
            }
            else
            {
                WindowsShareService.Show(owner, full);
            }
        }
        catch (Exception error)
        {
            App.UiLog($"Windows share failed: {error.GetType().Name}");
            _app.Toast.Show(L10n.T("menu.share_failed"));
        }
    }

    public static bool CanTranslate(ClipboardItem item) =>
        item.Content.Kind == ClipboardContentKind.Text
        && !item.IsUrl && !item.IsEmail && !item.IsCode
        && !string.IsNullOrWhiteSpace(item.TextValue);

    public void OpenTranslator(ClipboardItem item)
    {
        if (CanTranslate(item) && TryWriteClipboard(() => ClipboardWriter.Write(item)))
        {
            OpenInBrowser(new Uri("https://www.bing.com/translator"));
            _app.Toast.Show(L10n.T("menu.translate_paste"));
        }
    }

    /// <summary>Primary action: copy, close panel, restore previous app, send Ctrl+V.</summary>
    public void Paste(ClipboardItem item)
    {
        if (!TryWriteClipboard(() => ClipboardWriter.Write(_app.Store.RestoreFullResolutionItem(item))))
        {
            return;
        }
        var clipboardSequence = NativeMethods.GetClipboardSequenceNumber();
        ClosePanel();

        // Focus + SendInput can block briefly and must not freeze the UI thread;
        // elevated target windows may refuse SetForegroundWindow -> degrade to
        // "copied only" with a hint instead of pasting into the wrong window.
        var previousWindow = _previousForegroundWindow;
        Task.Run(() =>
        {
            var pasted = PasteBackService.RestoreAndPaste(previousWindow, clipboardSequence);
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
            CaptureForeground();
            var popover = new TrayPopoverWindow(_app);
            _trayPopover = popover;
            popover.Closed += (_, _) =>
            {
                if (_trayPopover == popover)
                {
                    _trayPopover = null;
                }
            };
            popover.Show();
            popover.Activate();
        }
    }

    // ---- secondary windows -------------------------------------------------------

    /// <summary>
    /// Tool windows are owned by the main panel (when visible) so they can
    /// never be buried under the always-on-top panel - the previous cause of
    /// 'Preferences opens but is invisible'.
    /// </summary>
    /// <summary>
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

    private System.Windows.Window? ToolOwner =>
        _mainWindow is { Visibility: System.Windows.Visibility.Visible } ? _mainWindow : null;

    public void ShowSettingsAfterMenu() =>
        _app.Dispatcher.InvokeAsync(ShowSettings, System.Windows.Threading.DispatcherPriority.Background);

    public void ShowSettings()
    {
        if (_settingsWindow is not { } window)
        {
            window = new SettingsWindow(_app);
            window.Closed += (_, _) =>
            {
                if (ReferenceEquals(_settingsWindow, window))
                {
                    _settingsWindow = null;
                }
            };
            _settingsWindow = window;
        }
        var owner = ToolOwner;
        if (window.Owner != owner)
        {
            window.Owner = owner;
        }
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }
        if (!window.IsVisible)
        {
            window.Show();
        }
        window.Activate();
    }

    public void ShowStatistics()
    {
        if (_statisticsWindow is { Visibility: Visibility.Visible })
        {
            if (_statisticsWindow.WindowState == WindowState.Minimized)
            {
                _statisticsWindow.WindowState = WindowState.Normal;
            }
            _statisticsWindow.Activate();
            ForceToFront(_statisticsWindow);
            return;
        }
        _statisticsWindow = new StatisticsWindow(_app) { Owner = ToolOwner };
        _statisticsWindow.Show();
        _statisticsWindow.Activate();
        ForceToFront(_statisticsWindow);
    }

    public void ShowDebug()
    {
        if (_debugWindow is { Visibility: Visibility.Visible })
        {
            _debugWindow.Activate();
            return;
        }
        _debugWindow = new DebugWindow(_app) { Owner = ToolOwner };
        _debugWindow.Show();
        _debugWindow.Activate();
        ForceToFront(_debugWindow);
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
        var window = new ImagePreviewWindow(_app, full) { Owner = ToolOwner };
        window.Show();
        window.Activate();
    }

    private void OpenTextPreview(ClipboardItem item)
    {
        var window = new TextPreviewWindow(_app, item) { Owner = ToolOwner };
        window.Show();
        window.Activate();
    }

    private void OpenFilePreview(ClipboardItem item)
    {
        var window = new FilePreviewWindow(_app, item) { Owner = ToolOwner };
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
                if (DragOutService.PathExists(path))
                {
                    OpenWithShell(path);
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
                    var result = NativeMethods.SHParseDisplayName(path, IntPtr.Zero, out var item, 0, out _);
                    Marshal.ThrowExceptionForHR(result);
                    try
                    {
                        Marshal.ThrowExceptionForHR(NativeMethods.SHOpenFolderAndSelectItems(item, 0, IntPtr.Zero, 0));
                    }
                    finally
                    {
                        Marshal.FreeCoTaskMem(item);
                    }
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
        if (paths.Count > 0 && TryWriteClipboard(() => Clipboard.SetText(string.Join(Environment.NewLine, paths))))
        {
            _app.Toast.Show(L10n.T("menu.copy_success"));
        }
    }

    private bool TryWriteClipboard(Action write)
    {
        try
        {
            _app.Monitor.WriteWithoutCapture(write);
            return true;
        }
        catch (Exception error)
        {
            App.UiLog($"Clipboard write failed: {error.GetType().Name}");
            _app.Toast.Show(L10n.T("menu.copy_failed"));
            return false;
        }
    }

    public void OpenInBrowser(Uri? url)
    {
        if (url is null)
        {
            return;
        }
        try
        {
            OpenWithShell(url.ToString());
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
            OpenWithShell(mailto.ToString());
        }
        catch (Exception)
        {
        }
    }

    private static void OpenWithShell(string target)
    {
        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName = target,
            UseShellExecute = true,
        };
        System.Diagnostics.Process.Start(startInfo);
    }
}
