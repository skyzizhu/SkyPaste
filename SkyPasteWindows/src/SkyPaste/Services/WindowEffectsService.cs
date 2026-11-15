using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace SkyPaste.Services;

/// <summary>
/// Windows 11 rounded window corners via DWM (DWMWA_WINDOW_CORNER_PREFERENCE).
/// No-ops automatically on Windows 10 where the attribute is unsupported.
/// </summary>
public static class WindowEffectsService
{
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWCP_ROUND = 2;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

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
