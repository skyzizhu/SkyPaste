using System.Buffers.Binary;
using System.Collections.Specialized;
using System.Runtime.InteropServices;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SkyPaste.Core.Core;
using SkyPaste.Core.Models;

namespace SkyPaste.Services;

/// <summary>
/// Reads the Windows clipboard with the macOS decoder's priority:
/// files (CF_HDROP) -> image (PNG format, then DIB) -> URL text -> plain text.
/// </summary>
public static class ClipboardDecoder
{
    private const int DibV5FormatId = 17;
    private static readonly Encoding AnsiEncoding = CodePagesEncodingProvider.Instance.GetEncoding(0) ?? Encoding.Latin1;

    public static ClipboardItem? Decode()
    {
        // 1. Files and folders.
        try
        {
            if (System.Windows.Clipboard.ContainsFileDropList())
            {
                var list = System.Windows.Clipboard.GetFileDropList();
                var paths = new List<string>();
                foreach (string? path in list)
                {
                    if (!string.IsNullOrWhiteSpace(path))
                    {
                        paths.Add(path);
                    }
                }
                if (paths.Count > 0)
                {
                    var item = new ClipboardItem(
                        Guid.NewGuid(), DateTime.UtcNow,
                        ClipboardContent.FromFileRefs(paths),
                        Fingerprint.ForFiles(paths),
                        ClipboardSource.Local, null);
                    return item;
                }
            }
        }
        catch (COMException)
        {
        }

        // 2. Images (PNG raw bytes first, then DIB).
        try
        {
            var imageData = TryReadImage(System.Windows.Clipboard.GetDataObject());
            SkyPaste.App.UiLog($"decode image: bytes={imageData?.LongLength ?? 0}");
            if (imageData is { Length: > 0 })
            {
                var name = InferImageName();
                var item = new ClipboardItem(
                    Guid.NewGuid(), DateTime.UtcNow,
                    ClipboardContent.FromImage(imageData, name, imageData.LongLength, previewOnly: false),
                    Fingerprint.ForImage(imageData),
                    ClipboardSource.Local, null);
                return item;
            }
        }
        catch (COMException)
        {
        }

        SkyPaste.App.UiLog("decode: no image payload captured");
        // 3. Native URL records and Unicode text (also used for email and code).
        try
        {
            var data = System.Windows.Clipboard.GetDataObject();
            if (data is not null)
            {
                var text = ReadText(data);
                if (!string.IsNullOrWhiteSpace(text))
                {
                    var item = new ClipboardItem(
                        Guid.NewGuid(), DateTime.UtcNow,
                        ClipboardContent.FromText(text),
                        Fingerprint.ForText(text),
                        ClipboardSource.Local, null);
                    return item;
                }
            }
        }
        catch (COMException)
        {
        }

        return null;
    }

    internal static string? ReadText(IDataObject data)
    {
        var url = ReadUrl(data, "UniformResourceLocatorW", Encoding.Unicode)
            ?? ReadUrl(data, "UniformResourceLocator", AnsiEncoding);
        return url ?? data.GetData(DataFormats.UnicodeText) as string ?? data.GetData(DataFormats.Text) as string;
    }

    private static string? ReadUrl(IDataObject data, string format, Encoding encoding)
    {
        try
        {
            var text = data.GetData(format, autoConvert: false) switch
            {
                string value => value,
                MemoryStream stream => encoding.GetString(stream.ToArray()),
                byte[] bytes => encoding.GetString(bytes),
                _ => null,
            };
            text = text?.Split('\0', 2)[0].Trim();
            return Uri.TryCreate(text, UriKind.Absolute, out var uri)
                && uri.Scheme is "http" or "https" or "mailto" ? text : null;
        }
        catch (COMException)
        {
            return null;
        }
    }

    internal static bool HasPngSignature(ReadOnlySpan<byte> data) =>
        data.StartsWith(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

    private static byte[]? TryReadImage(IDataObject? dataObject)
    {
        if (dataObject is null)
        {
            return null;
        }

        // Modern apps (browsers, Office) place raw PNG bytes under the "PNG" format.
        try
        {
            var png = ReadImageBytes(dataObject, "PNG");
            if (png is { Length: > 8 } && HasPngSignature(png)
                && ClipboardWriter.DecodeBitmap(png) is not null)
            {
                return png;
            }
        }
        catch (COMException)
        {
        }

        // CF_DIBV5 can carry an explicit alpha mask. Read the packed DIB
        // before asking WPF for an HBITMAP, which can lose that information.
        foreach (var format in new[] { DataFormats.GetDataFormat(DibV5FormatId).Name, DataFormats.Dib })
        {
            try
            {
                var dib = ReadImageBytes(dataObject, format);
                if (dib is not null && DecodeDib(dib) is { } bitmap)
                {
                    return EncodePng(bitmap);
                }
            }
            catch (Exception ex) when (ex is COMException or FormatException
                or NotSupportedException or ArgumentException)
            {
                // Try the next representation if this one cannot be decoded.
            }
        }

        try
        {
            if (dataObject.GetData(DataFormats.Bitmap) is BitmapSource source)
            {
                return EncodePng(AsOpaqueBitmapIfAlphaIsUnset(source));
            }
        }
        catch (COMException)
        {
        }
        return null;
    }

    private static byte[]? ReadImageBytes(IDataObject dataObject, string format) =>
        dataObject.GetData(format, autoConvert: false) switch
        {
            MemoryStream stream => stream.ToArray(),
            byte[] bytes => bytes,
            _ => null,
        };

    private static BitmapSource? DecodeDib(ReadOnlySpan<byte> dib)
    {
        if (dib.Length < 12)
        {
            return null;
        }

        var headerSize = BinaryPrimitives.ReadUInt32LittleEndian(dib);
        if (headerSize != 12 && (headerSize < 40 || headerSize > (uint)dib.Length))
        {
            return null;
        }

        var isCoreHeader = headerSize == 12;
        var bitsPerPixel = BinaryPrimitives.ReadUInt16LittleEndian(dib[(isCoreHeader ? 10 : 14)..]);
        var colorsUsed = isCoreHeader ? 0u : BinaryPrimitives.ReadUInt32LittleEndian(dib[32..]);
        var compression = isCoreHeader ? 0u : BinaryPrimitives.ReadUInt32LittleEndian(dib[16..]);
        if (colorsUsed == 0 && bitsPerPixel is 1 or 4 or 8)
        {
            colorsUsed = 1u << bitsPerPixel;
        }

        // The 40-byte header stores bit masks after the header. Newer headers
        // include the masks in the header itself.
        var maskBytes = headerSize == 40 ? compression switch { 3 => 12, 6 => 16, _ => 0 } : 0;
        var pixelOffset = (long)headerSize + maskBytes + (long)colorsUsed * (isCoreHeader ? 3 : 4);
        if (pixelOffset >= dib.Length)
        {
            return null;
        }

        // WIC decodes the bitmap once we prefix the packed DIB with a BMP file header.
        const int fileHeaderSize = 14;
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write((ushort)0x4D42);
        writer.Write((uint)(fileHeaderSize + (long)dib.Length));
        writer.Write(0u);
        writer.Write((uint)(fileHeaderSize + pixelOffset));
        writer.Write(dib);
        stream.Position = 0;
        var decoder = new BmpBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var bitmap = decoder.Frames[0];
        return compression == 0 ? AsOpaqueBitmapIfAlphaIsUnset(bitmap) : bitmap;
    }

    private static BitmapSource AsOpaqueBitmapIfAlphaIsUnset(BitmapSource source)
    {
        if (source.Format != PixelFormats.Bgra32 && source.Format != PixelFormats.Pbgra32)
        {
            return source;
        }

        // Some clipboard bitmaps have four bytes per pixel but never set alpha.
        // Keep their original BGR bytes and ignore the unused fourth byte.
        var stride = checked(source.PixelWidth * 4);
        var pixels = new byte[checked(stride * source.PixelHeight)];
        source.CopyPixels(pixels, stride, 0);
        for (var i = 3; i < pixels.Length; i += 4)
        {
            if (pixels[i] != 0)
            {
                return source;
            }
        }

        return BitmapSource.Create(source.PixelWidth, source.PixelHeight,
            source.DpiX, source.DpiY, PixelFormats.Bgr32, null, pixels, stride);
    }

    public static byte[] EncodePng(BitmapSource source)
    {
        var encoder = new PngBitmapEncoder();
        var frame = BitmapFrame.Create(source);
        encoder.Frames.Add(frame);
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    /// <summary>Mac infers the image name from a single accompanying file URL; same trick here.</summary>
    private static string? InferImageName()
    {
        try
        {
            if (System.Windows.Clipboard.ContainsFileDropList())
            {
                var list = System.Windows.Clipboard.GetFileDropList();
                if (list.Count == 1 && list[0] is { } path && ClipboardItem.IsImagePath(path))
                {
                    return Path.GetFileName(path);
                }
            }
        }
        catch (COMException)
        {
        }
        return null;
    }
}

/// <summary>Writes items back to the Windows clipboard (text / image / file drop list).</summary>
public static class ClipboardWriter
{
    public static void Write(ClipboardItem item) =>
        System.Windows.Clipboard.SetDataObject(CreateDataObject(item), copy: true);

    internal static DataObject CreateDataObject(ClipboardItem item)
    {
        switch (item.Content.Kind)
        {
            case ClipboardContentKind.Text:
                return new DataObject(DataFormats.UnicodeText, item.Content.Text ?? string.Empty);
            case ClipboardContentKind.Image:
            {
                var data = item.Content.ImageData ?? Array.Empty<byte>();
                var bitmap = DecodeBitmap(data);
                if (bitmap is null)
                {
                    throw new InvalidDataException("Could not decode the clipboard image.");
                }
                var dataObject = new DataObject();
                dataObject.SetImage(bitmap);
                var png = ClipboardDecoder.HasPngSignature(data) ? data : ClipboardDecoder.EncodePng(bitmap);
                dataObject.SetData("PNG", new MemoryStream(png), autoConvert: false);
                // CF_DIB for legacy apps (Paint, some Office paths) that ignore PNG/Bitmap formats.
                var dib = ConvertToDib(bitmap);
                if (dib is not null)
                {
                    dataObject.SetData(DataFormats.Dib, dib, autoConvert: false);
                }
                return dataObject;
            }
            case ClipboardContentKind.FileRefs:
                return CreateFileDropObject(item.Content.FilePaths ?? Array.Empty<string>());
            default:
                throw new InvalidDataException("Unsupported clipboard content.");
        }
    }

    internal static DataObject CreateFileDropObject(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
        {
            throw new InvalidDataException("No file paths to copy.");
        }
        var files = new StringCollection();
        foreach (var path in paths)
        {
            files.Add(path);
        }
        var dataObject = new DataObject();
        dataObject.SetFileDropList(files);
        const int dropEffectCopy = 1;
        dataObject.SetData("Preferred DropEffect", new MemoryStream(BitConverter.GetBytes(dropEffectCopy)), autoConvert: false);
        return dataObject;
    }

    /// <summary>Encodes a bitmap as a top-down 32bpp CF_DIB stream (BITMAPINFOHEADER + pixels).</summary>
    public static MemoryStream? ConvertToDib(BitmapSource source)
    {
        try
        {
            var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
            var width = converted.PixelWidth;
            var height = converted.PixelHeight;
            var stride = width * 4;
            var pixels = new byte[stride * height];
            converted.CopyPixels(pixels, stride, 0);

            const int headerSize = 40;
            var stream = new MemoryStream(headerSize + pixels.Length);
            using var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, leaveOpen: true);
            writer.Write((uint)headerSize);        // biSize
            writer.Write(width);                   // biWidth
            writer.Write(-height);                 // biHeight (negative = top-down)
            writer.Write((short)1);                // biPlanes
            writer.Write((short)32);               // biBitCount
            writer.Write(0u);                      // biCompression = BI_RGB
            writer.Write((uint)pixels.Length);     // biSizeImage
            writer.Write(0);                       // biXPelsPerMeter
            writer.Write(0);                       // biYPelsPerMeter
            writer.Write(0u);                      // biClrUsed
            writer.Write(0u);                      // biClrImportant
            writer.Write(pixels);
            stream.Position = 0;
            return stream;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static BitmapImage? DecodeBitmap(byte[] data)
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
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
