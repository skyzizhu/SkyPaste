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
        return thumbnail is not null && thumbnail.Length < original.Length
            ? item.Content.WithPreviewOnly(thumbnail).RebuildItem(item)
            : item;
    }

    /// <summary>Decode downsampled to maxDimension on the longest edge; returns PNG bytes.</summary>
    public static byte[]? CreateThumbnail(byte[] data, int maxDimension)
    {
        if (data.Length == 0 || maxDimension <= 0)
        {
            return null;
        }
        try
        {
            using var stream = new MemoryStream(data);
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.OnDemand).Frames[0];
            var width = frame.PixelWidth;
            var height = frame.PixelHeight;
            if (Math.Max(width, height) <= maxDimension)
            {
                return ClipboardDecoder.HasPngSignature(data) ? data : ClipboardDecoder.EncodePng(frame);
            }

            var image = new BitmapImage();
            using var decodeStream = new MemoryStream(data);
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            if (width >= height)
            {
                image.DecodePixelWidth = maxDimension;
            }
            else
            {
                image.DecodePixelHeight = maxDimension;
            }
            image.StreamSource = decodeStream;
            image.EndInit();
            image.Freeze();

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
        if (_cache.TryGetValue(key, out var cached) && cached.Length > 0)
        {
            return cached;
        }
        var bytes = ImageOptimizerService.CreateThumbnail(
            item.Content.ImageData ?? Array.Empty<byte>(), RowMaxPixelSize);
        // Never cache failures: a transient clipboard lock at capture time
        // must not blank the row forever.
        if (bytes is { Length: > 0 })
        {
            _cache[key] = bytes;
            return bytes;
        }
        return null;
    }

    /// <summary>Returns PNG thumbnail bytes for a single image file on disk.</summary>
    public byte[]? GetFileThumbnail(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        var key = path.ToLowerInvariant() + "#160";
        if (_cache.TryGetValue(key, out var cached) && cached.Length > 0)
        {
            return cached;
        }
        var bytes = ImageOptimizerService.CreateThumbnail(LoadFileBytes(path), RowMaxPixelSize);
        if (bytes is { Length: > 0 })
        {
            _cache[key] = bytes;
            return bytes;
        }
        return null;
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
