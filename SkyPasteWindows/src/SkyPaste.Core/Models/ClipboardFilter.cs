namespace SkyPaste.Core.Models;

/// <summary>
/// Port of macOS ClipboardFilter: fixed leading "all", fixed trailing "favorites",
/// 7 reorderable middle chips whose order is user-persisted.
/// </summary>
public enum ClipboardFilter
{
    All,
    Text,
    Image,
    File,
    Folder,
    Code,
    Url,
    Email,
    Favorites,
}

public static class ClipboardFilterExtensions
{
    public const string FilterOrderDefaultsKey = "settings.filterOrder";

    public static readonly ClipboardFilter FixedLeading = ClipboardFilter.All;
    public static readonly ClipboardFilter FixedTrailing = ClipboardFilter.Favorites;

    public static readonly IReadOnlyList<ClipboardFilter> ReorderableCases =
    [
        ClipboardFilter.Text, ClipboardFilter.Image, ClipboardFilter.File,
        ClipboardFilter.Folder, ClipboardFilter.Code, ClipboardFilter.Url, ClipboardFilter.Email,
    ];

    public static readonly IReadOnlyList<ClipboardFilter> DefaultDisplayOrder =
    [
        ClipboardFilter.All, ..ReorderableCases, ClipboardFilter.Favorites,
    ];

    public static bool Matches(this ClipboardFilter filter, ClipboardItem item) =>
        filter switch
        {
            ClipboardFilter.All => true,
            ClipboardFilter.Text => item.IsPlainText,
            ClipboardFilter.Image => item.IsImage || item.ContainsImageFiles,
            ClipboardFilter.File => item.ContainsFiles,
            ClipboardFilter.Folder => item.ContainsFolders,
            ClipboardFilter.Code => item.IsCode,
            ClipboardFilter.Url => item.IsUrl,
            ClipboardFilter.Email => item.IsEmail,
            ClipboardFilter.Favorites => item.IsFavorite,
            _ => false,
        };

    /// <summary>Localization key for the chip label.</summary>
    public static string LocalizationKey(this ClipboardFilter filter) =>
        filter switch
        {
            ClipboardFilter.All => "filter.all",
            ClipboardFilter.Text => "filter.text",
            ClipboardFilter.Image => "filter.image",
            ClipboardFilter.File => "filter.file",
            ClipboardFilter.Folder => "filter.folder",
            ClipboardFilter.Code => "filter.code",
            ClipboardFilter.Url => "filter.url",
            ClipboardFilter.Email => "filter.email",
            ClipboardFilter.Favorites => "filter.favorites",
            _ => "filter.all",
        };

    /// <summary>Segoe Fluent/Material icon glyph used by the WPF chips.</summary>
    public static string IconGlyph(this ClipboardFilter filter) =>
        filter switch
        {
            ClipboardFilter.All => "\uE8A9",      // GridView
            ClipboardFilter.Text => "\uE8D2",     // Text/align-left
            ClipboardFilter.Image => "\uE8B9",    // Photo
            ClipboardFilter.File => "\uE8A5",     // Document
            ClipboardFilter.Folder => "\uE8B7",   // Folder
            ClipboardFilter.Code => "\uE943",     // Code
            ClipboardFilter.Url => "\uE71B",      // Link
            ClipboardFilter.Email => "\uE715",    // Mail
            ClipboardFilter.Favorites => "\uE735",// Star
            _ => "\uE8A9",
        };

    /// <summary>Deduplicate, drop non-reorderable entries, and append anything missing in default order.</summary>
    public static IReadOnlyList<ClipboardFilter> NormalizeReorderableOrder(IEnumerable<ClipboardFilter> raw)
    {
        var seen = new HashSet<ClipboardFilter>();
        var result = new List<ClipboardFilter>();
        foreach (var filter in raw)
        {
            if (ReorderableCases.Contains(filter) && seen.Add(filter))
            {
                result.Add(filter);
            }
        }
        foreach (var filter in ReorderableCases)
        {
            if (seen.Add(filter))
            {
                result.Add(filter);
            }
        }
        return result;
    }

    public static IReadOnlyList<ClipboardFilter> FullDisplayOrder(IEnumerable<ClipboardFilter> reorderable)
    =>
    [
        FixedLeading, ..NormalizeReorderableOrder(reorderable), FixedTrailing,
    ];

    public static bool TryParse(string raw, out ClipboardFilter filter) =>
        Enum.TryParse(raw, ignoreCase: false, out filter);
}
