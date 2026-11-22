using SkyPaste.Core.Core;
using SkyPaste.Core.Localization;
using static SkyPaste.Core.Core.Classification;

namespace SkyPaste.Core.Models;

/// <summary>
/// Port of macOS ClipboardItem: immutable model whose classification and
/// search index are always derived at construction time (never persisted).
/// </summary>
public sealed class ClipboardItem
{
    public ClipboardItem(
        Guid id,
        DateTime createdAtUtc,
        ClipboardContent content,
        string fingerprint,
        ClipboardSource source,
        ClipboardSourceApp? sourceApp,
        bool isFavorite = false)
    {
        Id = id;
        CreatedAt = createdAtUtc;
        Content = content;
        Fingerprint = fingerprint;
        Source = source == ClipboardSource.Local ? source : ClipboardSource.LanDevice;
        // Only local items keep a source app; device-synced items carry the device name in SourceApp.Name.
        SourceApp = Source == ClipboardSource.Local ? sourceApp : null;
        DeviceName = Source == ClipboardSource.Local ? null : sourceApp?.Name;
        IsFavorite = isFavorite;
        IsSnippet = false;
        Classification = MakeClassification(content);
        SearchIndex = SearchIndexBuilder.Build(this);
    }

    public Guid Id { get; }
    public DateTime CreatedAt { get; } // UTC
    public ClipboardContent Content { get; }
    public string Fingerprint { get; }
    public ClipboardSource Source { get; }
    public ClipboardSourceApp? SourceApp { get; }
    public string? DeviceName { get; }
    public bool IsFavorite { get; set; }
    public bool IsSnippet { get; set; }
    public ClipboardClassification Classification { get; }
    public string SearchIndex { get; }

    // ---- classification conveniences ------------------------------------

    public bool IsPlainText => Classification.IsPlainText;
    public bool IsImage => Classification.IsImage;
    public bool IsUrl => Classification.IsUrl;
    public bool IsEmail => Classification.IsEmail;
    public bool IsCode => Classification.IsCode;

    public bool IsFileCollection => Content.Kind == ClipboardContentKind.FileRefs
                                    && Content.FilePaths is { Count: > 0 };

    public IReadOnlyList<string>? FilePaths => Content.FilePaths;

    public string? TextValue => Content.Kind == ClipboardContentKind.Text ? Content.Text : null;

    public Uri? BrowserUrl
    {
        get
        {
            if (!IsUrl || TextValue is null)
            {
                return null;
            }
            var trimmed = TextValue.Trim();
            if (Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
                && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
            {
                return uri;
            }
            if (Uri.TryCreate("https://" + trimmed, UriKind.Absolute, out var patched)
                && (patched.Scheme == Uri.UriSchemeHttp || patched.Scheme == Uri.UriSchemeHttps))
            {
                return patched;
            }
            return null;
        }
    }

    public string? EmailAddress => TextValue is null ? null : NormalizedEmailAddress(TextValue);

    public Uri? MailtoUrl => EmailAddress is null ? null : new Uri("mailto:" + EmailAddress);

    public string? PreviewText
    {
        get
        {
            if (Content.Kind == ClipboardContentKind.Text)
            {
                return Content.Text;
            }
            if (Content.Kind == ClipboardContentKind.Image && !string.IsNullOrWhiteSpace(Content.ImageName))
            {
                return Content.ImageName;
            }
            if (Content.Kind == ClipboardContentKind.FileRefs && Content.FilePaths is { Count: > 0 })
            {
                return string.Join(Environment.NewLine, Content.FilePaths);
            }
            return null;
        }
    }

    public bool SupportsTextPreview =>
        Content.Kind == ClipboardContentKind.Text && !string.IsNullOrWhiteSpace(Content.Text);

    public bool SupportsSaveAs => IsImage || IsFileCollection;

    public string SearchableText =>
        IsFavorite ? SearchIndex + "\nfavorite\nfavorites\nfav\n收藏" : SearchIndex;

    // ---- file helpers ----------------------------------------------------

    public IReadOnlyList<FileSystemItemKind> FileSystemKinds
    {
        get
        {
            if (!IsFileCollection)
            {
                return Array.Empty<FileSystemItemKind>();
            }
            var kinds = new List<FileSystemItemKind>();
            foreach (var path in Content.FilePaths!)
            {
                kinds.Add(FileSystemItemKindOf(path));
            }
            return kinds;
        }
    }

    public bool ContainsFiles => FileSystemKinds.Contains(FileSystemItemKind.File);
    public bool ContainsFolders => FileSystemKinds.Contains(FileSystemItemKind.Folder);

    public bool ContainsImageFiles =>
        IsFileCollection && Content.FilePaths!.Any(IsImagePath);

    public bool IsSingleImageFile => IsFileCollection
                                     && Content.FilePaths!.Count == 1
                                     && FileSystemItemKindOf(Content.FilePaths[0]) == FileSystemItemKind.File
                                     && IsImagePath(Content.FilePaths[0]);

    public bool IsSingleFile => IsFileCollection
                                && Content.FilePaths!.Count == 1
                                && FileSystemItemKindOf(Content.FilePaths[0]) == FileSystemItemKind.File;

    public bool IsSingleFolder => IsFileCollection
                                  && Content.FilePaths!.Count == 1
                                  && FileSystemItemKindOf(Content.FilePaths[0]) == FileSystemItemKind.Folder;

    public string? SingleFilePath => Content.FilePaths is { Count: 1 } paths ? paths[0] : null;

    public string? ContainingFolderPath => SingleFilePath is { } p ? Path.GetDirectoryName(p) : null;

    public static FileSystemItemKind FileSystemItemKindOf(string path) =>
        Directory.Exists(path) ? FileSystemItemKind.Folder : FileSystemItemKind.File;

    public static bool IsImagePath(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        return ext is "png" or "jpg" or "jpeg" or "gif" or "bmp" or "webp" or "tif" or "tiff" or "heic" or "heif" or "ico" or "svg" or "avif"
            or "tga" or "dng" or "exr" or "jp2" or "j2k" or "jxl" or "heics" or "raw" or "cr2" or "nef" or "arw" or "orf" or "rw2";
    }

    // ---- presentation ----------------------------------------------------

    public string Title
    {
        get
        {
            switch (Content.Kind)
            {
                case ClipboardContentKind.Text:
                {
                    var text = (Content.Text ?? string.Empty).Trim();
                    if (text.Length == 0)
                    {
                        return L10n.T("clipboard.empty_text");
                    }
                    if (IsEmail)
                    {
                        return text;
                    }
                    if (IsUrl)
                    {
                        return PrettyUrlTitle(text);
                    }
                    if (text.Length <= 90)
                    {
                        return text;
                    }
                    return text[..90] + "...";
                }
                case ClipboardContentKind.Image:
                    return string.IsNullOrWhiteSpace(Content.ImageName)
                        ? L10n.T("clipboard.image_fallback_name")
                        : Content.ImageName!;
                case ClipboardContentKind.FileRefs:
                {
                    var paths = Content.FilePaths ?? Array.Empty<string>();
                    if (paths.Count == 1)
                    {
                        var p = paths[0];
                        if (FileSystemItemKindOf(p) == FileSystemItemKind.Folder)
                        {
                            return L10n.Format("clipboard.folder_single", AbbreviateHome(p));
                        }
                        return L10n.Format("clipboard.file_single", Path.GetFileName(p));
                    }
                    var allFolders = paths.All(p => FileSystemItemKindOf(p) == FileSystemItemKind.Folder);
                    return allFolders
                        ? L10n.Format("clipboard.folder_count", paths.Count)
                        : L10n.Format("clipboard.file_count", paths.Count);
                }
                default:
                    return string.Empty;
            }
        }
    }

    public string Subtitle
    {
        get
        {
            switch (Content.Kind)
            {
                case ClipboardContentKind.Text:
                    if (IsEmail)
                    {
                        return L10n.T("filter.email");
                    }
                    if (IsUrl)
                    {
                        return L10n.T("filter.url");
                    }
                    return L10n.Format("clipboard.subtitle.text", (Content.Text ?? string.Empty).Length);
                case ClipboardContentKind.Image:
                    return L10n.Format("clipboard.subtitle.image", Math.Max(1, Content.OriginalByteCount / 1024));
                case ClipboardContentKind.FileRefs:
                {
                    var paths = Content.FilePaths ?? Array.Empty<string>();
                    if (paths.Count == 1)
                    {
                        var p = paths[0];
                        if (IsImagePath(p) && FileSystemItemKindOf(p) == FileSystemItemKind.File)
                        {
                            var ext = Path.GetExtension(p).TrimStart('.').ToUpperInvariant();
                            return ext.Length == 0
                                ? L10n.T("clipboard.subtitle.image_file")
                                : L10n.Format("clipboard.subtitle.image_file_format", ext);
                        }
                        return FileSystemItemKindOf(p) == FileSystemItemKind.Folder
                            ? L10n.T("clipboard.subtitle.folder")
                            : L10n.T("clipboard.subtitle.file");
                    }
                    // Mac: all folders -> folder_count; all image files ->
                    // image_file_count; otherwise file_count.
                    if (paths.All(p => FileSystemItemKindOf(p) == FileSystemItemKind.Folder))
                    {
                        return L10n.Format("clipboard.subtitle.folder_count", paths.Count);
                    }
                    if (paths.All(p => IsImagePath(p) && FileSystemItemKindOf(p) == FileSystemItemKind.File))
                    {
                        return L10n.Format("clipboard.subtitle.image_file_count", paths.Count);
                    }
                    return L10n.Format("clipboard.subtitle.file_count", paths.Count);
                }
                default:
                    return string.Empty;
            }
        }
    }

    public string OpenActionTitle
    {
        get
        {
            if (!IsFileCollection)
            {
                return L10n.T("menu.open_item");
            }
            if (Content.FilePaths is { Count: 1 } single)
            {
                return FileSystemItemKindOf(single[0]) == FileSystemItemKind.Folder
                    ? L10n.T("menu.open_folder")
                    : L10n.T("menu.open_file");
            }
            return L10n.T("menu.open_item");
        }
    }

    private static string PrettyUrlTitle(string raw)
    {
        var candidate = raw.Trim();
        if (!candidate.Contains("://"))
        {
            candidate = "https://" + candidate;
        }
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)
            || !SkyPaste.Core.Core.Classification.IsLikelyWebHost(uri.Host))
        {
            return raw;
        }
        var path = uri.AbsolutePath.TrimEnd('/');
        var segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var shown = string.Join("/", segments.Take(3));
        return shown.Length == 0 ? uri.Host : uri.Host + "/" + shown;
    }

    private static string AbbreviateHome(string path)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrEmpty(home) && path.StartsWith(home, StringComparison.OrdinalIgnoreCase))
        {
            return "~" + path[home.Length..];
        }
        return path;
    }

    private static ClipboardClassification MakeClassification(ClipboardContent content)
    {
        switch (content.Kind)
        {
            case ClipboardContentKind.Image:
                return new ClipboardClassification(false, true, false, false, false);
            case ClipboardContentKind.FileRefs:
                return new ClipboardClassification(false, false, false, false, false);
        }

        var text = content.Text ?? string.Empty;
        var isEmail = NormalizedEmailAddress(text) is not null;
        var isUrl = !isEmail && LooksLikeUrl(text);
        var isCode = !isEmail && LooksLikeCode(text, isUrl);
        var isPlainText = !isUrl && !isEmail;
        return new ClipboardClassification(isPlainText, false, isUrl, isEmail, isCode);
    }
}
