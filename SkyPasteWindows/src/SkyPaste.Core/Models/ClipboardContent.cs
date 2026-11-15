using System.Collections.ObjectModel;

namespace SkyPaste.Core.Models;

public enum ClipboardContentKind
{
    Text = 0,
    Image = 1,
    FileRefs = 2,
}

/// <summary>
/// One-of clipboard payload (mirrors macOS ClipboardContent: text / image / fileURLs).
/// </summary>
public sealed class ClipboardContent
{
    private ClipboardContent(
        ClipboardContentKind kind,
        string? text = null,
        byte[]? imageData = null,
        string? imageName = null,
        long originalByteCount = 0,
        bool previewOnly = false,
        IReadOnlyList<string>? filePaths = null)
    {
        Kind = kind;
        Text = text;
        ImageData = imageData;
        ImageName = imageName;
        OriginalByteCount = originalByteCount;
        PreviewOnly = previewOnly;
        FilePaths = filePaths is null ? null : new ReadOnlyCollection<string>(filePaths.ToList());
    }

    public ClipboardContentKind Kind { get; }
    public string? Text { get; }
    public byte[]? ImageData { get; }
    public string? ImageName { get; }
    public long OriginalByteCount { get; }
    public bool PreviewOnly { get; }
    public IReadOnlyList<string>? FilePaths { get; }

    public static ClipboardContent FromText(string text) =>
        new(ClipboardContentKind.Text, text: text);

    public static ClipboardContent FromImage(byte[] data, string? name, long originalByteCount, bool previewOnly) =>
        new(ClipboardContentKind.Image, imageData: data, imageName: name, originalByteCount: originalByteCount, previewOnly: previewOnly);

    public static ClipboardContent FromFileRefs(IReadOnlyList<string> paths) =>
        new(ClipboardContentKind.FileRefs, filePaths: paths);

    public ClipboardContent WithPreviewOnly(byte[] previewData) =>
        new(ClipboardContentKind.Image, imageData: previewData, imageName: ImageName,
            originalByteCount: OriginalByteCount, previewOnly: true);
}

public enum FileSystemItemKind
{
    File,
    Folder,
}

/// <summary>The five mutually computed classification flags (mirrors macOS Classification).</summary>
public sealed record ClipboardClassification(
    bool IsPlainText,
    bool IsImage,
    bool IsUrl,
    bool IsEmail,
    bool IsCode);
