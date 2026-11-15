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

        _window = new Window
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
                Foreground = (Brush)System.Windows.Application.Current.Resources["Toast.Foreground"],
            },
        };
        _window.Content = pill;

        _window.SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(_window).Handle;
            const int GWL_EXSTYLE = -20;
            const int WS_EX_TRANSPARENT = 0x20;
            const int WS_EX_NOACTIVATE = 0x08000000;
            const int WS_EX_TOOLWINDOW = 0x80;
            var exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);
            SetWindowLong(hwnd, GWL_EXSTYLE, exStyle | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
        };

        _window.Loaded += (_, _) =>
        {
            // Center on the primary work area (mac centers the toast on screen).
            var workArea = SystemParameters.WorkArea;
            _window.Left = (workArea.Width - _window.ActualWidth) / 2;
            _window.Top = workArea.Height * 0.42 - _window.ActualHeight / 2;

            var fadeIn = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(140));
            _window.BeginAnimation(Window.OpacityProperty, fadeIn);
        };

        _window.Show();

        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(950) };
        _hideTimer.Tick += (_, _) =>
        {
            _hideTimer?.Stop();
            if (_window is not null)
            {
                var fadeOut = new DoubleAnimation(0, TimeSpan.FromMilliseconds(180));
                fadeOut.Completed += (_, _) => Close();
                _window.BeginAnimation(Window.OpacityProperty, fadeOut);
            }
        };
        _hideTimer.Start();
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
