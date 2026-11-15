using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
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
    private double _lastLeft;
    private double _lastTop;
    private bool _hasLastPosition;
    private bool _pendingPlacement = true;

    public MainWindow(App app)
    {
        InitializeComponent();
        _app = app;
        Title = "SkyPaste";
        Width = 720;
        Height = 640;
        MinWidth = 660;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.CanResize;
        Background = (System.Windows.Media.Brush)FindResource("Window.Background");

        _panel = new ClipboardListPanel(app, popoverMode: false);
        PanelHost.Content = _panel;
        _panel.CloseRequested += ClosePanel;
    }

    private void ClosePanel() => ClosePanelInternal();

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

    private void ClosePanelInternal()
    {
        _lastLeft = Left;
        _lastTop = Top;
        _hasLastPosition = double.IsFinite(Left) && double.IsFinite(Top);
        Hide();
    }

    /// <summary>Panel placement: follow cursor / remember last / centered (default).</summary>
    private void PlacePanel()
    {
        switch (_app.Settings.PanelPosition)
        {
            case "cursor" when TryComputeCursorPlacement(out var cursorLeft, out var cursorTop):
                Left = cursorLeft;
                Top = cursorTop;
                return;
            case "remember" when _hasLastPosition:
                Left = _lastLeft;
                Top = _lastTop;
                return;
        }

        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Top + (area.Height - Height) / 2;
    }

    /// <summary>Centers the panel on the cursor using the nearest monitor's DPI.</summary>
    private bool TryComputeCursorPlacement(out double left, out double top)
    {
        left = top = 0;
        if (!NativeMethods.GetCursorPos(out var point))
        {
            return false;
        }
        var monitor = NativeMethods.MonitorFromPoint(point, NativeMethods.MONITOR_DEFAULTTONEAREST);
        var info = new NativeMethods.MONITORINFO { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFO>() };
        if (!NativeMethods.GetMonitorInfo(monitor, ref info)
            || NativeMethods.GetDpiForMonitor(monitor, 0, out var dpiX, out _) != 0)
        {
            return false;
        }
        var scale = dpiX / 96.0;
        if (scale <= 0)
        {
            return false;
        }

        left = (point.X - Width * scale / 2) / scale;
        top = (point.Y - Height * scale / 2) / scale;
        var workLeft = info.rcWork.Left / scale;
        var workTop = info.rcWork.Top / scale;
        var workRight = info.rcWork.Right / scale;
        var workBottom = info.rcWork.Bottom / scale;
        left = Math.Max(workLeft, Math.Min(left, workRight - Width));
        top = Math.Max(workTop, Math.Min(top, workBottom - Height));
        return true;
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
            ClosePanelInternal();
            return;
        }
        base.OnClosing(e);
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        WindowEffectsService.EnableRoundedCorners(this);
    }

}
