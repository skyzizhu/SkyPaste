using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace SkyPaste.Services;

/// <summary>
/// Port of the macOS copy-success toast: a click-through, topmost, borderless
/// pill centered on the primary screen that fades in and auto-dismisses.
/// </summary>
public sealed class ToastService
{
    private Window? _window;
    private DispatcherTimer? _hideTimer;

    public void Show(string message, bool compact = false)
    {
        var app = System.Windows.Application.Current;
        if (app is null)
        {
            return;
        }
        var dispatcher = app.Dispatcher;
        if (!dispatcher.CheckAccess())
        {
            dispatcher.BeginInvoke(() => Show(message, compact));
            return;
        }

        Close();

        var window = new Window
        {
            Style = null,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ShowInTaskbar = false,
            ShowActivated = false,
            Topmost = true,
            Width = double.NaN,
            SizeToContent = SizeToContent.WidthAndHeight,
            Opacity = 0,
        };
        _window = window;

        var pill = new Border
        {
            CornerRadius = new CornerRadius(compact ? 12 : 16),
            Padding = compact ? new Thickness(16, 8, 16, 8) : new Thickness(18, 9, 18, 9),
            MinWidth = compact ? 108 : 0,
            MinHeight = compact ? 36 : 0,
            // The HWND can be larger than its content at the system minimum size.
            HorizontalAlignment = compact ? HorizontalAlignment.Center : HorizontalAlignment.Stretch,
            VerticalAlignment = compact ? VerticalAlignment.Center : VerticalAlignment.Stretch,
            Background = (Brush)app.Resources["Toast.Background"],
            Child = new TextBlock
            {
                Text = message,
                FontSize = compact ? 14 : 13,
                FontWeight = FontWeights.Medium,
                MaxWidth = compact ? 220 : 360,
                TextAlignment = compact ? TextAlignment.Center : TextAlignment.Left,
                VerticalAlignment = compact ? VerticalAlignment.Center : VerticalAlignment.Stretch,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)app.Resources["Toast.Foreground"],
            },
        };
        window.Content = pill;

        window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            const int GWL_EXSTYLE = -20;
            const int WS_EX_TRANSPARENT = 0x20;
            const int WS_EX_NOACTIVATE = 0x08000000;
            const int WS_EX_TOOLWINDOW = 0x80;
            var exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
            SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };

        window.Loaded += (_, _) =>
        {
            // Center on the primary work area (mac centers the toast on screen).
            var workArea = SystemParameters.WorkArea;
            window.Left = workArea.Left + (workArea.Width - window.ActualWidth) / 2;
            window.Top = workArea.Top + (workArea.Height - window.ActualHeight) / 2;

            var fadeIn = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140));
            window.BeginAnimation(Window.OpacityProperty, fadeIn);
        };

        window.Show();

        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(950) };
        _hideTimer = timer;
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (_window == window)
            {
                var fadeOut = new DoubleAnimation(0, TimeSpan.FromMilliseconds(180));
                fadeOut.Completed += (_, _) =>
                {
                    if (_window == window)
                    {
                        Close();
                    }
                };
                window.BeginAnimation(Window.OpacityProperty, fadeOut);
            }
        };
        timer.Start();
    }

    public void Close()
    {
        _hideTimer?.Stop();
        _hideTimer = null;
        _window?.Close();
        _window = null;
    }

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hwnd, int index, int newStyle);
}
