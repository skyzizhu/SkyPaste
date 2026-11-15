using System.Runtime.InteropServices;
using System.Windows.Interop;
using SkyPaste.Core.Services;
using SkyPaste.Interop;

namespace SkyPaste.Services;

/// <summary>
/// Port of macOS HotKeyManager on RegisterHotKey: A-Z plus Ctrl/Shift/Alt/Win
/// modifier toggles, default Ctrl+Shift+V, re-registered whenever settings change.
/// </summary>
public sealed class GlobalHotKeyService : IDisposable
{
    private const int HotKeyId = 1;

    private readonly AppSettingsService _settings;
    private HwndSource? _hwndSource;
    private bool _registered;

    public event Action? Pressed;

    public GlobalHotKeyService(AppSettingsService settings)
    {
        _settings = settings;
        _settings.HotKeySettingsChanged += ApplyCurrentSetting;
    }

    public void Initialize()
    {
        if (_hwndSource is not null)
        {
            return;
        }
        var parameters = new HwndSourceParameters("SkyPasteHotKey")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
        };
        _hwndSource = new HwndSource(parameters);
        _hwndSource.AddHook(WndProc);
        ApplyCurrentSetting();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_HOTKEY && wParam.ToInt32() == HotKeyId)
        {
            handled = true;
            if (_hwndSource is not null)
            {
                _hwndSource.Dispatcher.BeginInvoke(() => Pressed?.Invoke());
            }
        }
        return IntPtr.Zero;
    }

    public void ApplyCurrentSetting()
    {
        if (_hwndSource is null)
        {
            return;
        }
        Unregister();
        if (!TryGetVirtualKey(_settings.HotKeyKey, out var virtualKey))
        {
            return;
        }
        var modifiers = NativeMethods.MOD_NOREPEAT;
        if (_settings.HotKeyCtrl)
        {
            modifiers |= NativeMethods.MOD_CONTROL;
        }
        if (_settings.HotKeyShift)
        {
            modifiers |= NativeMethods.MOD_SHIFT;
        }
        if (_settings.HotKeyAlt)
        {
            modifiers |= NativeMethods.MOD_ALT;
        }
        if (_settings.HotKeyWin)
        {
            modifiers |= NativeMethods.MOD_WIN;
        }
        _registered = NativeMethods.RegisterHotKey(_hwndSource.Handle, HotKeyId, modifiers, virtualKey);
    }

    private void Unregister()
    {
        if (_registered && _hwndSource is not null)
        {
            NativeMethods.UnregisterHotKey(_hwndSource.Handle, HotKeyId);
        }
        _registered = false;
    }

    private static bool TryGetVirtualKey(string key, out uint virtualKey)
    {
        if (key.Length == 1 && key[0] is >= 'A' and <= 'Z')
        {
            virtualKey = key[0]; // 'A'..'Z' map directly to VK codes
            return true;
        }
        virtualKey = 0;
        return false;
    }

    public void Dispose()
    {
        Unregister();
        _hwndSource?.Dispose();
        _hwndSource = null;
    }
}

/// <summary>
/// Port of the macOS paste-back flow: activate the previous app, then inject
/// Ctrl+V via SendInput (the Windows equivalent of CGEvent Cmd+V).
/// </summary>
public static class PasteBackService
{
    public static IntPtr CaptureForeground() => NativeMethods.GetForegroundWindow();

    public static void RestoreAndPaste(IntPtr previousWindow, int delayMs = 80)
    {
        if (previousWindow != IntPtr.Zero)
        {
            if (NativeMethods.IsIconic(previousWindow))
            {
                NativeMethods.ShowWindow(previousWindow, 9 /* SW_RESTORE */);
            }
            NativeMethods.SetForegroundWindow(previousWindow);
        }

        Thread.Sleep(delayMs);
        SendCtrlV();
    }

    public static void SendCtrlV()
    {
        var inputs = new NativeMethods.INPUT[4];
        const ushort VK_CONTROL = 0x11;
        const ushort VK_V = 0x56;

        inputs[0].type = NativeMethods.INPUT_KEYBOARD;
        inputs[0].U.ki.wVk = VK_CONTROL;

        inputs[1].type = NativeMethods.INPUT_KEYBOARD;
        inputs[1].U.ki.wVk = VK_V;

        inputs[2].type = NativeMethods.INPUT_KEYBOARD;
        inputs[2].U.ki.wVk = VK_V;
        inputs[2].U.ki.dwFlags = NativeMethods.KEYEVENTF_KEYUP;

        inputs[3].type = NativeMethods.INPUT_KEYBOARD;
        inputs[3].U.ki.wVk = VK_CONTROL;
        inputs[3].U.ki.dwFlags = NativeMethods.KEYEVENTF_KEYUP;

        NativeMethods.SendInput((uint)inputs.Length, inputs, NativeMethods.INPUT.Size);
    }
}
