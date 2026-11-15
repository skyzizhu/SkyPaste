using SkyPaste.Core.Models;

namespace SkyPaste.Core.Core;

/// <summary>
/// Port of macOS ClipboardDecoder fingerprint formats:
/// "txt:<text>", "img:<base64 of first 64 bytes>:<byte count>", "file:<p1>|<p2>".
/// The fingerprint doubles as the SQLite UNIQUE dedup key.
/// </summary>
public static class Fingerprint
{
    public static string ForText(string text) => "txt:" + text;

    public static string ForImage(byte[] data)
    {
        var prefix = Math.Min(data.Length, 64);
        var encoded = Convert.ToBase64String(data, 0, prefix);
        return $"img:{encoded}:{data.Length}";
    }

    public static string ForFiles(IReadOnlyList<string> paths) => "file:" + string.Join("|", paths);

    public static string For(ClipboardContent content) =>
        content.Kind switch
        {
            ClipboardContentKind.Text => ForText(content.Text ?? string.Empty),
            ClipboardContentKind.Image => ForImage(content.ImageData ?? Array.Empty<byte>()),
            ClipboardContentKind.FileRefs => ForFiles(content.FilePaths ?? Array.Empty<string>()),
            _ => throw new ArgumentOutOfRangeException(nameof(content)),
        };
}
