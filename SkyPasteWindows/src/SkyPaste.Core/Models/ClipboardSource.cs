namespace SkyPaste.Core.Models;

/// <summary>Where a clipboard item came from. Mirrors macOS ClipboardSource (cloudKit merged into LanDevice).</summary>
public enum ClipboardSource
{
    Local = 0,
    LanDevice = 1,
}

public static class ClipboardSourceExtensions
{
    public static bool IsDeviceSynced(this ClipboardSource source) => source == ClipboardSource.LanDevice;

    public static string? DeviceIconGlyph(this ClipboardSource source) =>
        source switch
        {
            ClipboardSource.LanDevice => "\uD83D\uDCF1", // phone emoji fallback; UI replaces with vector
            _ => null,
        };

    public static string BadgeText(this ClipboardSource source) =>
        source switch
        {
            ClipboardSource.Local => SkyPaste.Core.Localization.L10n.T("preview.source_local"),
            ClipboardSource.LanDevice => SkyPaste.Core.Localization.L10n.T("clipboard.source.device"),
            _ => string.Empty,
        };

    public static IReadOnlyList<string> SearchKeywords(this ClipboardSource source) =>
        source switch
        {
            ClipboardSource.Local => new[] { "local", "mac", "this mac", "pc", "本机", "本地", "这台电脑" },
            ClipboardSource.LanDevice => new[] { "phone", "iphone", "universal", "universal clipboard", "手机", "iphone 剪贴板", "通用剪贴板", "icloud", "cloud", "sync", "云", "云同步", "icloud sync", "lan", "device", "局域网", "设备", "同步" },
            _ => Array.Empty<string>(),
        };
}

/// <summary>Bundle/process identity of the app that produced a local clipboard item.</summary>
public sealed record ClipboardSourceApp(string ProcessId, string Name, string? ExecutablePath = null);
