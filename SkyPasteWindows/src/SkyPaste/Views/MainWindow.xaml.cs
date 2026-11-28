using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using SkyPaste.Core.Services;
using SkyPaste.Interop;
using SkyPaste.Views.Controls;

using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Main panel window (mac: 700x620 floating NSPanel, centered, topmost,
/// Esc closes, Enter pastes, Ctrl+1..9 quick copy, stays visible on deactivate).
/// </summary>
public partial class MainWindow : Window
{
    private readonly App _app;
    private readonly ClipboardListPanel _panel;

    public MainWindow(App app)
    {
        InitializeComponent();
        _app = app;
        Title = "SkyPaste";
        Width = 720;
        Height = 640;
        MinWidth = 660;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.CanResize;

        _panel = new ClipboardListPanel(app, popoverMode: false);
        PanelHost.Content = _panel;
        _panel.CloseRequested += ClosePanel;
    }

    internal void ClosePanel()
    {
        RememberPosition();
        Hide();
    }

    public void ShowPanel()
    {
        _app.Coordinator.CaptureForeground();
        _panel.RefreshLocalization();
        PlacePanel();
        Show();
        Activate();
        Focus();
        _panel.Focus();
        _panel.OnStoreChanged();
    }

    private void RememberPosition()
    {
        if (IsVisible && WindowState == WindowState.Normal && _app.Settings.PanelPosition == "remember"
            && NativeMethods.GetWindowRect(new WindowInteropHelper(this).Handle, out var bounds))
        {
            _app.Settings.LastPanelLocation = new AppSettingsService.PanelLocation(bounds.Left, bounds.Top);
        }
    }

    private void PlacePanel()
    {
        var saved = _app.Settings.PanelPosition == "remember" ? _app.Settings.LastPanelLocation : null;
        var hasCursor = NativeMethods.GetCursorPos(out var cursor);
        var anchor = saved is not null ? new NativeMethods.POINT { X = saved.X, Y = saved.Y } : cursor;
        var monitor = NativeMethods.MonitorFromPoint(anchor, NativeMethods.MONITOR_DEFAULTTONEAREST);
        var info = new NativeMethods.MONITORINFO { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFO>() };
        if (!NativeMethods.GetMonitorInfo(monitor, ref info))
        {
            var area = SystemParameters.WorkArea;
            Left = area.Left + (area.Width - Width) / 2;
            Top = area.Top + (area.Height - Height) / 2;
            return;
        }
        var scale = NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out var dpi, out _) == 0
            ? dpi / 96.0 : 1.0;
        var width = (int)Math.Round(Width * scale);
        var height = (int)Math.Round(Height * scale);
        var work = info.rcWork;
        var followCursor = _app.Settings.PanelPosition == "cursor" && hasCursor;
        var x = saved?.X ?? (followCursor ? cursor.X - width / 2 : work.Left + (work.Right - work.Left - width) / 2);
        var y = saved?.Y ?? (followCursor ? cursor.Y - height / 2 : work.Top + (work.Bottom - work.Top - height) / 2);
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        // Screen pixels keep the placement consistent across mixed-DPI monitors.
        NativeMethods.SetWindowPos(hwnd, IntPtr.Zero,
            Math.Clamp(x, work.Left, Math.Max(work.Left, work.Right - width)),
            Math.Clamp(y, work.Top, Math.Max(work.Top, work.Bottom - height)),
            0, 0, 0x0001 | 0x0004 | 0x0010); // SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
    }

    public void OnStoreChanged() => _panel.OnStoreChanged();

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        if (_panel.HandleKeyDown(e.Key, Keyboard.Modifiers))
        {
            e.Handled = true;
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // The panel hides rather than closing (orderOut semantics).
        if (System.Windows.Application.Current is not null
            && !System.Windows.Application.Current.Dispatcher.HasShutdownStarted)
        {
            e.Cancel = true;
            ClosePanel();
            return;
        }
        RememberPosition();
        base.OnClosing(e);
    }

}
