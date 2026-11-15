using System.Collections.Concurrent;
using System.IO;
using System.Windows.Media.Imaging;
using SkyPaste.Core.Models;

namespace SkyPaste.Services;

/// <summary>
/// Port of ClipboardImageOptimizer: full images become <=240px PNG thumbnails
/// in memory; the original bytes stay in SQLite and are restored on copy.
/// </summary>
public static class ImageOptimizerService
{
    public const int PreviewMaxDimension = 240;

    public static ClipboardItem MemoryOptimize(ClipboardItem item)
    {
        if (item.Content.Kind != ClipboardContentKind.Image || item.Content.PreviewOnly)
        {
            return item;
        }
        var original = item.Content.ImageData ?? Array.Empty<byte>();
        var thumbnail = CreateThumbnail(original, PreviewMaxDimension);
        return thumbnail is not null
            ? item.Content.WithPreviewOnly(thumbnail).RebuildItem(item)
            : item;
    }

    /// <summary>Decode downsampled to maxDimension on the longest edge; returns PNG bytes.</summary>
    public static byte[]? CreateThumbnail(byte[] data, int maxDimension)
    {
        if (data.Length == 0)
        {
            return null;
        }
        try
        {
            var image = new BitmapImage();
            using var stream = new MemoryStream(data);
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.DecodePixelWidth = maxDimension;
            image.DecodePixelHeight = maxDimension;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();

            // DecodePixelWidth/Height keep aspect ratio; encode the thumbnail back to PNG.
            return ClipboardDecoder.EncodePng(image);
        }
        catch (Exception)
        {
            return null;
        }
    }
}

internal static class ClipboardItemExtensions
{
    /// <summary>Rebuilds an item with the given (preview) content, preserving identity fields.</summary>
    public static ClipboardItem RebuildItem(this ClipboardContent content, ClipboardItem source)
    {
        return new ClipboardItem(
            source.Id, source.CreatedAt, content, source.Fingerprint, source.Source,
            source.SourceApp ?? (source.DeviceName is null ? null : new ClipboardSourceApp("device", source.DeviceName)),
            source.IsFavorite);
    }
}

/// <summary>
/// Port of ClipboardPreviewImageProvider: 160px thumbnails for list rows, async
/// with a bounded cache and request-key race protection done by the caller.
/// </summary>
public sealed class ThumbnailProvider
{
    public const int RowMaxPixelSize = 160;

    private readonly ConcurrentDictionary<string, byte[]> _cache = new();

    public static ThumbnailProvider Shared { get; } = new();

    /// <summary>Returns PNG thumbnail bytes for an image item (or null when unavailable).</summary>
    public byte[]? GetImageThumbnail(ClipboardItem item)
    {
        if (item.Content.Kind != ClipboardContentKind.Image)
        {
            return null;
        }
        var key = item.Id + "#image-data";
        return _cache.GetOrAdd(key, _ =>
            ImageOptimizerService.CreateThumbnail(item.Content.ImageData ?? Array.Empty<byte>(), RowMaxPixelSize)
            ?? Array.Empty<byte>()) is { Length: > 0 } bytes ? bytes : null;
    }

    /// <summary>Returns PNG thumbnail bytes for a single image file on disk.</summary>
    public byte[]? GetFileThumbnail(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        return _cache.GetOrAdd(path.ToLowerInvariant() + "#160", _ =>
            ImageOptimizerService.CreateThumbnail(LoadFileBytes(path), RowMaxPixelSize)
            ?? Array.Empty<byte>()) is { Length: > 0 } bytes ? bytes : null;
    }

    private static byte[] LoadFileBytes(string path)
    {
        try
        {
            return File.ReadAllBytes(path);
        }
        catch (Exception)
        {
            return Array.Empty<byte>();
        }
    }

    public void Clear()
    {
        _cache.Clear();
    }
}
