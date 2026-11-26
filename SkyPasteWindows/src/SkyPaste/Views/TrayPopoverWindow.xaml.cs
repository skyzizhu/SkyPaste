using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using SkyPaste.Interop;
using SkyPaste.Views.Controls;

using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Tray popover (mac: 396x520 NSPopover, closes on outside click / deactivation,
/// list shows up to 80 items, single click copies only).
/// </summary>
public partial class TrayPopoverWindow : Window
{
    private readonly ClipboardListPanel _panel;
    private bool _showingDialog;
    private bool _openingShare;

    public TrayPopoverWindow(App app)
    {
        InitializeComponent();
        Title = "SkyPaste";
        Width = 400;
        Height = 540;
        MinWidth = 360;
        MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.CanResize;
        SetResourceReference(BackgroundProperty, "Window.Background");

        _panel = new ClipboardListPanel(app, popoverMode: true);
        PanelHost.Content = _panel;
        _panel.CloseRequested += () => Close();

        Deactivated += (_, _) =>
        {
            if (_openingShare)
            {
                _openingShare = false;
                return;
            }
            if (!_showingDialog)
            {
                Close();
            }
        };
        Activated += (_, _) => Topmost = true;
        Closed += (_, _) => _panel.ReleaseSubscriptions();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        WindowEffectsService.EnableRoundedCorners(this);
        if (!NativeMethods.GetCursorPos(out var cursor))
        {
            return;
        }
        var monitor = NativeMethods.MonitorFromPoint(cursor, NativeMethods.MONITOR_DEFAULTTONEAREST);
        var info = new NativeMethods.MONITORINFO { cbSize = Marshal.SizeOf<NativeMethods.MONITORINFO>() };
        if (!NativeMethods.GetMonitorInfo(monitor, ref info))
        {
            return;
        }
        var scale = NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MDT_EFFECTIVE_DPI, out var dpi, out _) == 0
            ? dpi / 96.0 : 1.0;
        var work = info.rcWork;
        var width = Math.Min((int)Math.Round(Width * scale), work.Right - work.Left);
        var height = Math.Min((int)Math.Round(Height * scale), work.Bottom - work.Top);
        var x = cursor.X - width / 2;
        var y = cursor.Y > work.Top + (work.Bottom - work.Top) / 2 ? cursor.Y - height : cursor.Y;
        if (cursor.X < work.Left || cursor.X >= work.Right)
        {
            x = cursor.X < work.Left ? work.Left : work.Right - width;
            y = cursor.Y - height / 2;
        }
        NativeMethods.SetWindowPos(new WindowInteropHelper(this).Handle, IntPtr.Zero,
            Math.Clamp(x, work.Left, work.Right - width), Math.Clamp(y, work.Top, work.Bottom - height),
            width, height, 0x0004 | 0x0010); // SWP_NOZORDER | SWP_NOACTIVATE
    }

    public void OnStoreChanged() => _panel.OnStoreChanged();

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        if (_panel.HandleKeyDown(e.Key, Keyboard.Modifiers))
        {
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Escape && !_panel.IsSearchFocused)
        {
            Close();
            e.Handled = true;
        }
    }

    internal void RunDialog(Action showDialog)
    {
        _showingDialog = true;
        try
        {
            showDialog();
        }
        finally
        {
            _showingDialog = false;
        }
    }

    internal void ShowSystemShare(Action showShare)
    {
        _openingShare = true;
        Topmost = false;
        try
        {
            showShare();
        }
        catch
        {
            _openingShare = false;
            Topmost = true;
            throw;
        }
        var timeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timeout.Tick += (_, _) =>
        {
            timeout.Stop();
            if (_openingShare)
            {
                _openingShare = false;
                if (IsActive)
                {
                    Topmost = true;
                }
            }
        };
        timeout.Start();
    }
}
