using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;

namespace SkyPaste.Services;

/// <summary>
/// Finder-style stacked drag preview (mac ClipboardDragPreviewComposer):
/// renders up to 3 stacked thumbnails into a 96x96Bitmap + TEXT drag image
/// (DADs) data and attaches it via IDragSourceHelper so Explorer shows the
/// custom preview instead of the default ghost rectangle.
/// </summary>
public static class DragPreviewService
{
    private const int MaxVisibleThumbnails = 3;
    private const int PreviewSize = 64;
    private const int CanvasSize = 96;

    /// <summary>
    /// Renders the stacked preview for an item and returns it as a 32bpp BGRA
    /// pixel buffer premultiplied-alpha ready (row-major, top-down).
    /// </summary>
    public static byte[]? RenderPreviewPixels(ClipboardItem item, int pixelSize)
    {
        try
        {
            var visual = new DrawingVisual();
            using (var context = visual.RenderOpen())
            {
                DrawStack(context, item, pixelSize);
            }
            var bitmap = new RenderTargetBitmap(pixelSize, pixelSize, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            return ToPremultipliedBgra(bitmap);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static void DrawStack(DrawingContext context, ClipboardItem item, int pixelSize)
    {
        var scale = pixelSize / (double)CanvasSize;
        context.PushTransform(new ScaleTransform(scale, scale));

        var sources = CollectThumbnailSources(item);
        var offsetStep = 13;
        var iconSize = PreviewSize;

        // Draw back-to-front with a diagonal stack like Finder.
        var count = Math.Min(sources.Count, MaxVisibleThumbnails);
        for (var layer = count - 1; layer >= 0; layer--)
        {
            var x = 8 + (count - 1 - layer) * offsetStep;
            var y = 8 + (count - 1 - layer) * offsetStep;

            var imageSource = sources[layer];
            var rounded = new RectangleGeometry(
                new Rect(0, 0, iconSize, iconSize), 9, 9);
            context.PushClip(rounded);
            context.DrawImage(imageSource, new Rect(x, y, iconSize, iconSize));
            context.Pop();

            context.DrawRoundedRectangle(
                null,
                new Pen(new SolidColorBrush(Color.FromArgb(40, 0, 0, 0)), 1),
                new Rect(x, y, iconSize, iconSize), 9, 9);
        }

        // Count badge on the top layer.
        if (item.IsFileCollection && (item.Content.FilePaths?.Count ?? 0) > MaxVisibleThumbnails)
        {
            var badgeX = 8 + (count - 1) * offsetStep + iconSize - 19;
            var badgeY = 8 + (count - 1) * offsetStep;
            context.DrawEllipse(
                new SolidColorBrush(Color.FromRgb(0x14, 0x6B, 0xF0)),
                new Pen(Brushes.White, 1.5),
                new Point(badgeX + 9.5, badgeY + 9.5), 9.5, 9.5);
            var text = new FormattedText(
                "+",
                System.Globalization.CultureInfo.CurrentCulture,
                FlowDirection.LeftToRight,
                new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                12,
                Brushes.White,
                1.25);
            context.DrawText(text, new Point(badgeX + 9.5 - text.Width / 2, badgeY + 9.5 - text.Height / 2));
        }
        else if (item.IsFileCollection && item.Content.FilePaths is { Count: > 1 })
        {
            var badgeX = 8 + (count - 1) * offsetStep + iconSize - 19;
            var badgeY = 8 + (count - 1) * offsetStep;
            context.DrawEllipse(
                new SolidColorBrush(Color.FromRgb(0x14, 0x6B, 0xF0)),
                new Pen(Brushes.White, 1.5),
                new Point(badgeX + 9.5, badgeY + 9.5), 9.5, 9.5);
            var text = new FormattedText(
                item.Content.FilePaths.Count.ToString(),
                System.Globalization.CultureInfo.CurrentCulture,
                FlowDirection.LeftToRight,
                new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                11,
                Brushes.White,
                1.25);
            context.DrawText(text, new Point(badgeX + 9.5 - text.Width / 2, badgeY + 9.5 - text.Height / 2));
        }
    }

    private static List<ImageSource> CollectThumbnailSources(ClipboardItem item)
    {
        var sources = new List<ImageSource>();
        if (item.IsImage)
        {
            var bitmap = ClipboardWriter.DecodeBitmap(item.Content.ImageData ?? Array.Empty<byte>());
            if (bitmap is not null)
            {
                sources.Add(bitmap);
            }
            return sources;
        }

        foreach (var path in (item.Content.FilePaths ?? Array.Empty<string>())
                     .Where(File.Exists)
                     .Take(MaxVisibleThumbnails))
        {
            if (ClipboardItem.IsImagePath(path))
            {
                var thumb = ThumbnailProvider.Shared.GetFileThumbnail(path);
                var bitmap = thumb is not null ? ClipboardWriter.DecodeBitmap(thumb) : null;
                if (bitmap is not null)
                {
                    sources.Add(bitmap);
                    continue;
                }
            }
            var icon = FileIconProvider.Extract(path);
            if (icon is not null)
            {
                sources.Add(icon);
            }
        }
        return sources;
    }

    private static byte[] ToPremultipliedBgra(RenderTargetBitmap bitmap)
    {
        var size = bitmap.PixelWidth * bitmap.PixelHeight * 4;
        var pixels = new byte[size];
        bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0);
        return pixels;
    }

    /// <summary>
    /// Writes the drag-image data (DragDropHelper formats) into the DataObject so
    /// the shell's IDragSourceHelper path renders our preview in Explorer.
    /// </summary>
    public static void AttachPreview(ClipboardItem item, DataObject dataObject)
    {
        var pixels = RenderPreviewPixels(item, CanvasSize);
        if (pixels is null)
        {
            return;
        }

        // DragDropHelper drop description / image formats (DADs).
        var header = new SHDRAGIMAGE
        {
            sizeDragImage = new SIZE { cx = CanvasSize, cy = CanvasSize },
            ptOffset = new POINT { x = CanvasSize / 2 - PreviewSize / 2, y = CanvasSize / 2 - PreviewSize / 2 },
            crColorHighlight = 0,
        };
        var headerBytes = StructToBytes(header);
        var payload = new byte[headerBytes.Length + pixels.Length];
        Buffer.BlockCopy(headerBytes, 0, payload, 0, headerBytes.Length);
        Buffer.BlockCopy(pixels, 0, payload, headerBytes.Length, pixels.Length);

        using var stream = new MemoryStream(payload);
        dataObject.SetData("DragImageBits", stream);
        dataObject.SetData("DragContext", Array.Empty<byte>());
        dataObject.SetData("DropDescription", Array.Empty<byte>());
    }

    private static byte[] StructToBytes(SHDRAGIMAGE structure)
    {
        var size = Marshal.SizeOf<SHDRAGIMAGE>();
        var buffer = new byte[size];
        var ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(structure, ptr, fDeleteOld: false);
            Marshal.Copy(ptr, buffer, 0, size);
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
        return buffer;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SHDRAGIMAGE
    {
        public SIZE sizeDragImage;
        public POINT ptOffset;
        public int crColorHighlight;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SIZE
    {
        public int cx;
        public int cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

}
