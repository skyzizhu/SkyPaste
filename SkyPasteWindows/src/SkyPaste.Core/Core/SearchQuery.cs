using SkyPaste.Core.Models;

namespace SkyPaste.Core.Core;

public enum SearchItemTypeScope
{
    Text,
    Image,
    File,
    Folder,
    Code,
    Url,
    Email,
}

public enum SearchDateScope
{
    Today,
    Yesterday,
}

public enum SearchSourceScope
{
    Local,
    Device,
}

/// <summary>
/// Port of macOS ClipboardSearchQuery: whitespace-separated tokens, whole query
/// lowercased first. Special tokens: fav/favorite/favorites/收藏, today|今天,
/// yesterday|昨天, type:/is: prefixes, source:/ prefixes. Unknown tokens become
/// AND'ed substring terms matched against the lowercase search index.
/// </summary>
public sealed class SearchQuery
{
    private static readonly Dictionary<string, SearchItemTypeScope> TypeTokens = new(StringComparer.Ordinal)
    {
        ["type:text"] = SearchItemTypeScope.Text,
        ["is:text"] = SearchItemTypeScope.Text,
        ["type:image"] = SearchItemTypeScope.Image,
        ["type:img"] = SearchItemTypeScope.Image,
        ["is:image"] = SearchItemTypeScope.Image,
        ["type:file"] = SearchItemTypeScope.File,
        ["type:files"] = SearchItemTypeScope.File,
        ["is:file"] = SearchItemTypeScope.File,
        ["type:folder"] = SearchItemTypeScope.Folder,
        ["type:directory"] = SearchItemTypeScope.Folder,
        ["type:dir"] = SearchItemTypeScope.Folder,
        ["is:folder"] = SearchItemTypeScope.Folder,
        ["is:directory"] = SearchItemTypeScope.Folder,
        ["type:code"] = SearchItemTypeScope.Code,
        ["is:code"] = SearchItemTypeScope.Code,
        ["type:url"] = SearchItemTypeScope.Url,
        ["type:link"] = SearchItemTypeScope.Url,
        ["is:url"] = SearchItemTypeScope.Url,
        ["type:email"] = SearchItemTypeScope.Email,
        ["type:mail"] = SearchItemTypeScope.Email,
        ["is:email"] = SearchItemTypeScope.Email,
        ["is:mail"] = SearchItemTypeScope.Email,
    };

    private static readonly string[] FavoriteTokens = { "fav", "favorite", "favorites", "收藏" };
    private static readonly string[] TodayTokens = { "today", "今天" };
    private static readonly string[] YesterdayTokens = { "yesterday", "昨天" };
    private static readonly string[] LocalSourceTokens = { "source:mac", "source:local", "source:pc" };
    private static readonly string[] DeviceSourceTokens =
    {
        "source:phone", "source:iphone", "source:universal", "source:device",
        "source:icloud", "source:cloud",
    };

    private readonly string[] _terms;

    public SearchQuery(string rawValue)
    {
        RawValue = rawValue ?? string.Empty;
        var lowered = RawValue.Trim().ToLowerInvariant();
        var terms = new List<string>();
        foreach (var token in lowered.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (FavoriteTokens.Contains(token))
            {
                FavoritesOnly = true;
            }
            else if (TodayTokens.Contains(token))
            {
                Dates.Add(SearchDateScope.Today);
            }
            else if (YesterdayTokens.Contains(token))
            {
                Dates.Add(SearchDateScope.Yesterday);
            }
            else if (TypeTokens.TryGetValue(token, out var type))
            {
                Types.Add(type);
            }
            else if (LocalSourceTokens.Contains(token))
            {
                Sources.Add(SearchSourceScope.Local);
            }
            else if (DeviceSourceTokens.Contains(token))
            {
                Sources.Add(SearchSourceScope.Device);
            }
            else
            {
                terms.Add(token);
            }
        }
        _terms = terms.ToArray();
    }

    public string RawValue { get; }

    public bool FavoritesOnly { get; private set; }
    public HashSet<SearchItemTypeScope> Types { get; } = new();
    public HashSet<SearchSourceScope> Sources { get; } = new();
    public HashSet<SearchDateScope> Dates { get; } = new();
    public IReadOnlyList<string> Terms => _terms;

    public bool IsEmpty => !FavoritesOnly && Types.Count == 0 && Sources.Count == 0 && Dates.Count == 0 && _terms.Length == 0;

    public bool Matches(ClipboardItem item)
    {
        if (FavoritesOnly && !item.IsFavorite)
        {
            return false;
        }
        if (Types.Count > 0 && !Types.Any(t => MatchesType(item, t)))
        {
            return false;
        }
        if (Sources.Count > 0 && !Sources.Any(s => MatchesSource(item, s)))
        {
            return false;
        }
        if (Dates.Count > 0 && !Dates.Any(d => MatchesDate(item, d)))
        {
            return false;
        }
        var searchable = item.SearchableText;
        foreach (var term in _terms)
        {
            if (!searchable.Contains(term, StringComparison.Ordinal))
            {
                return false;
            }
        }
        return true;
    }

    private static bool MatchesType(ClipboardItem item, SearchItemTypeScope type) =>
        type switch
        {
            SearchItemTypeScope.Text => item.IsPlainText,
            SearchItemTypeScope.Image => item.IsImage,
            SearchItemTypeScope.File => item.ContainsFiles,
            SearchItemTypeScope.Folder => item.ContainsFolders,
            SearchItemTypeScope.Code => item.IsCode,
            SearchItemTypeScope.Url => item.IsUrl,
            SearchItemTypeScope.Email => item.IsEmail,
            _ => false,
        };

    private static bool MatchesSource(ClipboardItem item, SearchSourceScope scope) =>
        scope switch
        {
            SearchSourceScope.Local => item.Source == ClipboardSource.Local,
            SearchSourceScope.Device => item.Source.IsDeviceSynced(),
            _ => false,
        };

    private static bool MatchesDate(ClipboardItem item, SearchDateScope scope)
    {
        var local = item.CreatedAt.ToLocalTime().Date;
        var today = DateTime.Today;
        return scope switch
        {
            SearchDateScope.Today => local == today,
            SearchDateScope.Yesterday => local == today.AddDays(-1),
            _ => false,
        };
    }
}

/// <summary>Source-app dropdown option (mirrors ClipboardSourceAppOption).</summary>
public sealed record ClipboardSourceAppOption(string ProcessId, string Name, string? ExecutablePath = null);

/// <summary>
/// Selected source scope for filtering (mirrors ClipboardSourceSelection:
/// allApps / phone / app(bundleID) — Windows uses process id).
/// </summary>
public sealed class ClipboardSourceSelection : IEquatable<ClipboardSourceSelection>
{
    public enum SelectionKind
    {
        AllApps,
        Device,
        App,
    }

    private ClipboardSourceSelection(SelectionKind kind, string? processId = null)
    {
        Kind = kind;
        ProcessId = processId;
    }

    public static ClipboardSourceSelection AllApps { get; } = new(SelectionKind.AllApps);
    public static ClipboardSourceSelection Device { get; } = new(SelectionKind.Device);

    public SelectionKind Kind { get; }
    public string? ProcessId { get; }

    public string CacheKey => Kind switch
    {
        SelectionKind.AllApps => "all-apps",
        SelectionKind.Device => "device",
        SelectionKind.App => "app:" + ProcessId,
        _ => "all-apps",
    };

    public bool Matches(ClipboardItem item) =>
        Kind switch
        {
            SelectionKind.AllApps => true,
            SelectionKind.Device => item.Source.IsDeviceSynced(),
            SelectionKind.App => item.SourceApp?.ProcessId == ProcessId,
            _ => true,
        };

    public bool Equals(ClipboardSourceSelection? other) =>
        other is not null && Kind == other.Kind && ProcessId == other.ProcessId;

    public override bool Equals(object? obj) => Equals(obj as ClipboardSourceSelection);

    public override int GetHashCode() => HashCode.Combine(Kind, ProcessId);

    public static ClipboardSourceSelection ForApp(string processId) => new(SelectionKind.App, processId);
}
