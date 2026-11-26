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

    public void Show(string message)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null)
        {
            return;
        }
        if (!dispatcher.CheckAccess())
        {
            dispatcher.BeginInvoke(() => Show(message));
            return;
        }

        Close();

        var window = new Window
        {
            WindowStyle = WindowStyle.None,
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
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(18, 9, 18, 9),
            Background = (Brush)System.Windows.Application.Current.Resources["Toast.Background"],
            Child = new TextBlock
            {
                Text = message,
                FontSize = 13,
                FontWeight = FontWeights.Medium,
                MaxWidth = 360,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)System.Windows.Application.Current.Resources["Toast.Foreground"],
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
