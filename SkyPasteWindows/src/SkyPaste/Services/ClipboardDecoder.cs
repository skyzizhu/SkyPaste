using System.Collections.Specialized;
using System.Runtime.InteropServices;
using System.IO;
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
    public static ClipboardItem? Decode()
    {
        // 1. Files and folders.
        try
        {
            if (System.Windows.Clipboard.ContainsFileDropList())
            {
                var list = System.Windows.Clipboard.GetFileDropList();
                var paths = new List<string>();
                foreach (string path in list)
                {
                    paths.Add(path);
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
            var imageData = TryReadImage();
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
        // 3. Text (URLs and emails are classified downstream).
        try
        {
            if (System.Windows.Clipboard.ContainsText())
            {
                var text = System.Windows.Clipboard.GetText();
                text = text.TrimStart('\n', '\r');
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

    private static byte[]? TryReadImage()
    {
        var dataObject = System.Windows.Clipboard.GetDataObject();

        // Modern apps (browsers, Office) place raw PNG bytes under the "PNG" format.
        try
        {
            if (dataObject?.GetDataPresent("PNG") == true)
            {
                if (dataObject.GetData("PNG") is MemoryStream pngStream)
                {
                    var bytes = pngStream.ToArray();
                    if (bytes.Length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50)
                    {
                        return bytes;
                    }
                }
                else if (dataObject.GetData("PNG") is byte[] pngBytes
                         && pngBytes.Length > 8 && pngBytes[0] == 0x89)
                {
                    return pngBytes;
                }
            }
        }
        catch (COMException)
        {
        }

        try
        {
            if (dataObject?.GetDataPresent(DataFormats.Bitmap) == true
                && dataObject.GetData(DataFormats.Bitmap) is BitmapSource source)
            {
                return EncodePng(source);
            }
        }
        catch (COMException)
        {
        }
        return null;
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
                if (list.Count == 1 && ClipboardItem.IsImagePath(list[0]))
                {
                    return Path.GetFileName(list[0]);
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
    public static void Write(ClipboardItem item)
    {
        switch (item.Content.Kind)
        {
            case ClipboardContentKind.Text:
                System.Windows.Clipboard.SetText(item.Content.Text ?? string.Empty);
                break;
            case ClipboardContentKind.Image:
            {
                var data = item.Content.ImageData ?? Array.Empty<byte>();
                var bitmap = DecodeBitmap(data);
                if (bitmap is null)
                {
                    return;
                }
                var dataObject = new DataObject();
                dataObject.SetImage(bitmap);
                try
                {
                    dataObject.SetData("PNG", new MemoryStream(data));
                }
                catch (COMException)
                {
                }
                // CF_DIB for legacy apps (Paint, some Office paths) that ignore PNG/Bitmap formats.
                var dib = ConvertToDib(bitmap);
                if (dib is not null)
                {
                    try
                    {
                        dataObject.SetData(DataFormats.Dib, dib);
                    }
                    catch (COMException)
                    {
                    }
                }
                System.Windows.Clipboard.SetDataObject(dataObject, copy: true);
                break;
            }
            case ClipboardContentKind.FileRefs:
            {
                var files = new StringCollection();
                foreach (var path in item.Content.FilePaths ?? Array.Empty<string>())
                {
                    files.Add(path);
                }
                if (files.Count == 0)
                {
                    return;
                }
                var dataObject = new DataObject();
                dataObject.SetFileDropList(files);
                // "Copy" drop effect so Explorer pastes rather than moves.
                dataObject.SetData("Preferred DropEffect", BitConverter.GetBytes(2));
                System.Windows.Clipboard.SetDataObject(dataObject, copy: true);
                break;
            }
        }
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
