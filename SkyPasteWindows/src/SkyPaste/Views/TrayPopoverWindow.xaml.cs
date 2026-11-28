using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using SkyPaste.Interop;
using SkyPaste.Views.Controls;

using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Tray clipboard list, anchored to the display that contains the tray click.
/// </summary>
public partial class TrayPopoverWindow : Window
{
    private const double DefaultWidth = 440;
    private const double DefaultHeight = 660;
    private const double MinimumWidth = 360;
    private const double MinimumHeight = 460;
    private readonly ClipboardListPanel _panel;
    private readonly Button[] _captionButtons;
    private readonly DispatcherTimer _dismissTimer = new(DispatcherPriority.Background)
    {
        Interval = TimeSpan.FromMilliseconds(120),
    };
    private bool _showingDialog;
    private bool _openingShare;
    private bool _closing;

    public TrayPopoverWindow(App app)
    {
        InitializeComponent();
        Title = "SkyPaste";
        Width = DefaultWidth;
        Height = DefaultHeight;
        MinWidth = MinimumWidth;
        MinHeight = MinimumHeight;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.CanResize;

        _panel = new ClipboardListPanel(app, popoverMode: true);
        PanelHost.Content = _panel;
        var actions = _panel.DetachHeaderActions();
        CaptionActions.Content = actions;
        _captionButtons = actions.Children.OfType<Button>().ToArray();
        var captionButtonStyle = (Style)FindResource("TrayCaptionButton");
        foreach (var button in _captionButtons)
        {
            button.Style = captionButtonStyle;
            button.Margin = new Thickness(0);
            if (button.Content is TextBlock icon)
            {
                icon.FontSize = 15;
            }
        }
        _panel.CloseRequested += () => Close();

        Deactivated += (_, _) =>
        {
            if (_openingShare)
            {
                _openingShare = false;
                return;
            }
            if (!_showingDialog && !_closing)
            {
                // The shell can deactivate this window on mouse-down before
                // NotifyIcon delivers the click on mouse-up.
                _dismissTimer.Start();
            }
        };
        _dismissTimer.Tick += (_, _) =>
        {
            const int leftButton = 0x01;
            const int rightButton = 0x02;
            if (NativeMethods.GetAsyncKeyState(leftButton) < 0 || NativeMethods.GetAsyncKeyState(rightButton) < 0)
            {
                return;
            }
            _dismissTimer.Stop();
            if (!_showingDialog && !_closing && !IsActive)
            {
                Close();
            }
        };
        Activated += (_, _) =>
        {
            _dismissTimer.Stop();
            Topmost = true;
        };
        ContentRendered += (_, _) => AlignCaptionActions();
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(DispatcherPriority.Loaded, AlignCaptionActions);
        Closed += (_, _) => _panel.ReleaseSubscriptions();
    }

    private void AlignCaptionActions()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero || !WindowEffectsService.TryGetCaptionButtonBounds(hwnd, out var caption)
            || !NativeMethods.GetWindowRect(hwnd, out var window))
        {
            return;
        }

        var topLeft = PopoverLayout.PointFromScreen(new Point(window.Left + caption.Left, window.Top + caption.Top));
        var bottomRight = PopoverLayout.PointFromScreen(new Point(window.Left + caption.Right, window.Top + caption.Bottom));
        var width = bottomRight.X - topLeft.X;
        var height = bottomRight.Y - topLeft.Y;
        CaptionBar.Height = height;
        CaptionBar.Margin = new Thickness(CaptionBar.Margin.Left, topLeft.Y,
            PopoverLayout.ActualWidth - topLeft.X, 0);
        foreach (var button in _captionButtons)
        {
            button.Width = width;
            button.Height = height;
        }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;
        // Keep the native close button and resizable edges while removing the
        // two caption buttons whose space is used by the tray actions.
        const int styleIndex = -16;
        const int minimizeBox = 0x00020000;
        const int maximizeBox = 0x00010000;
        var style = NativeMethods.GetWindowLong(hwnd, styleIndex);
        NativeMethods.SetWindowLong(hwnd, styleIndex, style & ~(minimizeBox | maximizeBox));
        const int refreshFrame = 0x0020 | 0x0010 | 0x0004 | 0x0002 | 0x0001;
        NativeMethods.SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, refreshFrame);
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
        var work = info.rcWork;
        var workWidth = work.Right - work.Left;
        var workHeight = work.Bottom - work.Top;
        if (workWidth <= 0 || workHeight <= 0 || !NativeMethods.GetWindowRect(hwnd, out var bounds))
        {
            return;
        }

        const int noActivateOrReorder = 0x0004 | 0x0010;
        const int noSize = 0x0001;
        // Move the hidden window to the target monitor before querying its DPI.
        NativeMethods.SetWindowPos(hwnd, IntPtr.Zero,
            work.Left + (workWidth - (bounds.Right - bounds.Left)) / 2,
            work.Top + (workHeight - (bounds.Bottom - bounds.Top)) / 2,
            0, 0, noActivateOrReorder | noSize);
        var dpi = NativeMethods.GetDpiForWindow(hwnd);
        var scale = dpi == 0 ? 1.0 : dpi / 96.0;
        var size = GetDefaultSize(workWidth / scale, workHeight / scale);
        MinWidth = Math.Min(MinimumWidth, size.Width);
        MinHeight = Math.Min(MinimumHeight, size.Height);
        Width = size.Width;
        Height = size.Height;

        var width = Math.Min((int)Math.Round(size.Width * scale), workWidth);
        var height = Math.Min((int)Math.Round(size.Height * scale), workHeight);
        var x = cursor.X - width / 2;
        var y = cursor.Y > work.Top + (work.Bottom - work.Top) / 2 ? cursor.Y - height : cursor.Y;
        if (cursor.X < work.Left || cursor.X >= work.Right)
        {
            x = cursor.X < work.Left ? work.Left : work.Right - width;
            y = cursor.Y - height / 2;
        }
        NativeMethods.SetWindowPos(hwnd, IntPtr.Zero,
            Math.Clamp(x, work.Left, work.Right - width), Math.Clamp(y, work.Top, work.Bottom - height),
            width, height, noActivateOrReorder);
    }

    internal static Size GetDefaultSize(double workWidth, double workHeight) =>
        new(
            Math.Min(workWidth, DefaultWidth + Math.Clamp((workWidth - 1600) * 0.14, 0, 120)),
            Math.Min(workHeight, DefaultHeight + Math.Clamp((workHeight - 920) * 0.375, 0, 180)));

    public void OnStoreChanged() => _panel.OnStoreChanged();

    protected override void OnClosing(CancelEventArgs e)
    {
        _closing = true;
        _dismissTimer.Stop();
        base.OnClosing(e);
        _closing = !e.Cancel;
    }

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
