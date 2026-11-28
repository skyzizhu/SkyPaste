using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using SkyPaste.Interop;

namespace SkyPaste.Services;

/// <summary>
/// Windows 11 rounded window corners via DWM (DWMWA_WINDOW_CORNER_PREFERENCE).
/// No-ops automatically on Windows 10 where the attribute is unsupported.
/// </summary>
public static class WindowEffectsService
{
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_CAPTION_BUTTON_BOUNDS = 5;
    private const int DWMWCP_ROUND = 2;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out NativeMethods.RECT value, int size);

    internal static bool TryGetCaptionButtonBounds(IntPtr hwnd, out NativeMethods.RECT bounds) =>
        DwmGetWindowAttribute(hwnd, DWMWA_CAPTION_BUTTON_BOUNDS, out bounds, Marshal.SizeOf<NativeMethods.RECT>()) == 0
        && bounds.Right > bounds.Left && bounds.Bottom > bounds.Top;

    /// <summary>Call from OnSourceInitialized; safe on Win10 (call just fails).</summary>
    public static void EnableRoundedCorners(Window window)
    {
        try
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero)
            {
                return;
            }
            var preference = DWMWCP_ROUND;
            DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref preference, sizeof(int));
        }
        catch (Exception)
        {
            // Older systems or headless sessions: ignore.
        }
    }
}
