using System.Collections.Concurrent;
using SkyPaste.Core.Core;
using SkyPaste.Core.Data;
using SkyPaste.Core.Models;

namespace SkyPaste.Core.Services;

/// <summary>
/// Port of macOS ClipboardStore: owns the visible item list, the per-filter
/// buckets, the search/filter pipeline (async with generation guard), history
/// trimming, favorites, and batch operations. Statistics are recorded on add.
/// </summary>
public sealed class ClipboardStore
{
    private readonly ClipboardDatabase _database;
    private readonly StatisticsDatabase _statistics;
    private readonly AppSettingsService _settings;
    private readonly ConcurrentDictionary<int, CancellationTokenSource> _filterGenerations = new();
    private int _filterGeneration;

    /// <summary>Set by the WPF layer to swap full images for memory-friendly thumbnails.</summary>
    public Func<ClipboardItem, ClipboardItem>? MemoryOptimizer { get; set; }

    /// <summary>Raised for each newly captured LOCAL item (used for LAN upload).</summary>
    public event Action<ClipboardItem>? OnLocalItemAdded;

    /// <summary>Raised after any list mutation; the UI re-renders.</summary>
    public event Action? ItemsChanged;

    /// <summary>Raised every time a statistic is recorded (statistics view reloads).</summary>
    public event Action? StatisticsChanged;

    public ClipboardStore(ClipboardDatabase database, StatisticsDatabase statistics, AppSettingsService settings)
    {
        _database = database;
        _statistics = statistics;
        _settings = settings;
        _settings.HistoryLimitChanged += ApplyHistoryLimit;

        LoadInitial();
    }

    public string? StartupNotice { get; private set; }

    private void LoadInitial()
    {
        var backup = ClipboardDatabase.RecoverIfCorrupted(_database.DatabasePath);
        if (backup is not null)
        {
            StartupNotice = Localization.L10n.T("notice.database_recovered");
        }

        try
        {
            var loaded = _database.LoadVisibleItems(_settings.HistoryLimit);
            Items = loaded.Select(i => MemoryOptimizer?.Invoke(i) ?? i).ToList();
        }
        catch (Exception)
        {
            Items = new List<ClipboardItem>();
        }
        _statistics.SeedRetainedHistoryIfNeeded(Items);
        UpdateFilteredItemsSync();
    }

    // ---- state -----------------------------------------------------------

    public List<ClipboardItem> Items { get; private set; } = new();

    public IReadOnlyDictionary<ClipboardFilter, IReadOnlyList<ClipboardItem>> FilteredItemsByFilter { get; private set; }
        = DefaultBuckets();

    public IReadOnlyDictionary<ClipboardFilter, IReadOnlyList<ClipboardSourceAppOption>> SourceAppOptionsByFilter { get; private set; }
        = new Dictionary<ClipboardFilter, IReadOnlyList<ClipboardSourceAppOption>>();

    public string AppliedSearchText { get; private set; } = string.Empty;

    private static IReadOnlyDictionary<ClipboardFilter, IReadOnlyList<ClipboardItem>> DefaultBuckets() =>
        ClipboardFilterExtensions.DefaultDisplayOrder.ToDictionary(
            f => f, _ => (IReadOnlyList<ClipboardItem>)Array.Empty<ClipboardItem>());

    // ---- adding ------------------------------------------------------------

    /// <summary>Port of macOS add(): privacy filter, favorite inheritance, top-dedupe, insert at head, trim.</summary>
    public void Add(ClipboardItem rawItem)
    {
        var item = MemoryOptimizer?.Invoke(rawItem) ?? rawItem;

        if (SensitiveContentFilter.ShouldExclude(item.TextValue, item.SourceApp, _settings.PrivacyFilteringEnabled))
        {
            return;
        }

        // Inherit favorite state from an existing item with the same fingerprint.
        var existingFavorite = Items.FirstOrDefault(i => i.Fingerprint == item.Fingerprint)?.IsFavorite
                               ?? _database.FavoriteStateForFingerprint(item.Fingerprint);
        if (existingFavorite == true)
        {
            item.IsFavorite = true;
        }

        // Top-of-list duplicate: refresh timestamp only when something meaningful changed.
        if (Items.Count > 0 && Items[0].Fingerprint == item.Fingerprint)
        {
            if (!ShouldRefreshTopItem(Items[0], item))
            {
                return;
            }
            var refreshed = RecreateWithTimestamp(item, DateTime.UtcNow);
            Persist(refreshed);
            ReplaceTop(refreshed);
            return;
        }

        Persist(item);
        Items.RemoveAll(i => i.Fingerprint == item.Fingerprint);
        Items.Insert(0, item);
        EnforceHistoryLimit();
        UpdateFilteredItemsSync();
        if (item.Source == ClipboardSource.Local)
        {
            OnLocalItemAdded?.Invoke(item);
        }
        ItemsChanged?.Invoke();
    }

    /// <summary>Device/phone ingest: last-write-wins by createdAt, inserted chronologically.</summary>
    public void AddDeviceSyncedItem(ClipboardItem incoming)
    {
        if (SensitiveContentFilter.ShouldExclude(incoming.TextValue, null, _settings.PrivacyFilteringEnabled))
        {
            return;
        }
        var existing = Items.FirstOrDefault(i => i.Fingerprint == incoming.Fingerprint);
        if (existing is not null && incoming.CreatedAt <= existing.CreatedAt)
        {
            return; // incoming is not newer -> ignore
        }
        if (existing is not null)
        {
            Items.Remove(existing);
        }
        var item = MemoryOptimizer?.Invoke(incoming) ?? incoming;
        Persist(item);

        var index = Items.FindIndex(i => i.CreatedAt < item.CreatedAt);
        if (index < 0)
        {
            Items.Add(item);
        }
        else
        {
            Items.Insert(index, item);
        }
        EnforceHistoryLimit();
        UpdateFilteredItemsSync();
        StatisticsChanged?.Invoke();
        ItemsChanged?.Invoke();
    }

    private static bool ShouldRefreshTopItem(ClipboardItem oldItem, ClipboardItem newItem) =>
        oldItem.Source != newItem.Source
        || oldItem.Title != newItem.Title
        || oldItem.Subtitle != newItem.Subtitle
        || oldItem.IsFavorite != newItem.IsFavorite;

    private static ClipboardItem RecreateWithTimestamp(ClipboardItem item, DateTime utcNow)
    {
        var replacement = new ClipboardItem(
            item.Id, utcNow, item.Content, item.Fingerprint, item.Source, item.SourceApp ?? (item.DeviceName is null ? null : new ClipboardSourceApp("device", item.DeviceName)), item.IsFavorite);
        return replacement;
    }

    private void Persist(ClipboardItem item)
    {
        try
        {
            _database.Save(item, _settings.HistoryLimit);
        }
        catch (Exception)
        {
            // Persist failures must not break the in-memory history.
        }
        _statistics.Record(item);
        StatisticsChanged?.Invoke();
    }

    // ---- list management ---------------------------------------------------

    private void ReplaceTop(ClipboardItem item)
    {
        Items[0] = item;
        UpdateFilteredItemsSync();
        ItemsChanged?.Invoke();
    }

    /// <summary>Favorites always survive; newest N non-favorites are kept (0 -> favorites only).</summary>
    private void ApplyHistoryLimit()
    {
        Items = ApplyingHistoryLimit(Items, _settings.HistoryLimit).ToList();
        try
        {
            _database.TrimToLimit(_settings.HistoryLimit);
        }
        catch (Exception)
        {
        }
        UpdateFilteredItemsSync();
        ItemsChanged?.Invoke();
    }

    public static IEnumerable<ClipboardItem> ApplyingHistoryLimit(IEnumerable<ClipboardItem> items, int limit)
    {
        var nonFavoriteCount = 0;
        foreach (var item in items)
        {
            if (item.IsFavorite)
            {
                yield return item;
            }
            else if (nonFavoriteCount < limit)
            {
                nonFavoriteCount += 1;
                yield return item;
            }
        }
    }

    private void EnforceHistoryLimit()
    {
        Items = ApplyingHistoryLimit(Items, _settings.HistoryLimit).ToList();
    }

    // ---- search/filter pipeline --------------------------------------------

    public void SetSearchQuery(string query)
    {
        AppliedSearchText = query.Trim();
        if (AppliedSearchText.Length == 0)
        {
            UpdateFilteredItemsSync();
            return;
        }
        var generation = Interlocked.Increment(ref _filterGeneration);
        var cts = new CancellationTokenSource();
        _filterGenerations[generation] = cts;
        var items = Items.ToList();
        var searchQuery = new SearchQuery(AppliedSearchText);

        Task.Run(() =>
        {
            try
            {
                var filtered = MakeFilteredItemsByFilter(items, searchQuery, cts.Token);
                var options = MakeSourceAppOptionsByFilter(filtered);
                if (generation != Volatile.Read(ref _filterGeneration))
                {
                    return; // stale result
                }
                FilteredItemsByFilter = filtered;
                SourceAppOptionsByFilter = options;
                ItemsChanged?.Invoke();
            }
            catch (OperationCanceledException)
            {
            }
            finally
            {
                _filterGenerations.TryRemove(generation, out _);
                cts.Dispose();
            }
        }, cts.Token);
    }

    private static Dictionary<ClipboardFilter, IReadOnlyList<ClipboardItem>> MakeFilteredItemsByFilter(
        IReadOnlyList<ClipboardItem> items, SearchQuery query, CancellationToken token)
    {
        var matched = new List<ClipboardItem>(items.Count);
        foreach (var item in items)
        {
            if (query.Matches(item))
            {
                matched.Add(item);
            }
            token.ThrowIfCancellationRequested();
        }

        var buckets = new Dictionary<ClipboardFilter, List<ClipboardItem>>();
        foreach (var filter in ClipboardFilterExtensions.DefaultDisplayOrder)
        {
            buckets[filter] = new List<ClipboardItem>();
        }
        foreach (var item in matched)
        {
            foreach (var filter in ClipboardFilterExtensions.DefaultDisplayOrder)
            {
                if (filter.Matches(item))
                {
                    buckets[filter].Add(item);
                }
            }
        }
        return buckets.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<ClipboardItem>)kv.Value);
    }

    private static IReadOnlyDictionary<ClipboardFilter, IReadOnlyList<ClipboardSourceAppOption>> MakeSourceAppOptionsByFilter(
        IReadOnlyDictionary<ClipboardFilter, IReadOnlyList<ClipboardItem>> buckets)
    {
        var result = new Dictionary<ClipboardFilter, IReadOnlyList<ClipboardSourceAppOption>>();
        foreach (var (filter, items) in buckets)
        {
            var options = items
                .Where(i => i.SourceApp is not null)
                .Select(i => i.SourceApp!)
                .DistinctBy(app => app.ProcessId)
                .OrderBy(app => app.Name, StringComparer.CurrentCultureIgnoreCase)
                .Select(app => new ClipboardSourceAppOption(app.ProcessId, app.Name))
                .ToList();
            result[filter] = options;
        }
        return result;
    }

    private void UpdateFilteredItemsSync()
    {
        Interlocked.Increment(ref _filterGeneration);
        var query = new SearchQuery(AppliedSearchText);
        var filtered = MakeFilteredItemsByFilter(Items, query, CancellationToken.None);
        FilteredItemsByFilter = filtered;
        SourceAppOptionsByFilter = MakeSourceAppOptionsByFilter(filtered);
        ItemsChanged?.Invoke();
    }

    // ---- full-resolution restore --------------------------------------------

    /// <summary>Preview-only image items reload the full image from the database for copy-back.</summary>
    public ClipboardItem RestoreFullResolutionItem(ClipboardItem item)
    {
        if (item.Content.Kind == ClipboardContentKind.Image && item.Content.PreviewOnly)
        {
            try
            {
                var full = _database.LoadItem(item.Id);
                if (full is not null)
                {
                    return full;
                }
            }
            catch (Exception)
            {
            }
        }
        return item;
    }

    // ---- favorites -----------------------------------------------------------

    public void SetFavorite(ClipboardItem item, bool favorite)
    {
        item.IsFavorite = favorite;
        try
        {
            _database.SetFavorite(item.Id, favorite);
            if (!favorite)
            {
                _database.TrimToLimit(_settings.HistoryLimit);
            }
        }
        catch (Exception)
        {
        }
        Items = ApplyingHistoryLimit(Items, _settings.HistoryLimit).ToList();
        UpdateFilteredItemsSync();
    }

    public void SetFavorites(IReadOnlyCollection<Guid> ids, bool favorite)
    {
        foreach (var item in Items)
        {
            if (ids.Contains(item.Id))
            {
                item.IsFavorite = favorite;
            }
        }
        try
        {
            ClipboardDatabase.SetFavorites(_database.DatabasePath, ids, favorite, _settings.HistoryLimit);
        }
        catch (Exception)
        {
        }
        Items = ApplyingHistoryLimit(Items, _settings.HistoryLimit).ToList();
        UpdateFilteredItemsSync();
    }

    // ---- deletion -------------------------------------------------------------

    public void DeleteItem(ClipboardItem item)
    {
        try
        {
            _database.DeleteItem(item.Id);
        }
        catch (Exception)
        {
        }
        Items.Remove(item);
        UpdateFilteredItemsSync();
    }

    public void DeleteItems(IReadOnlyCollection<Guid> ids)
    {
        Items.RemoveAll(i => ids.Contains(i.Id));
        try
        {
            ClipboardDatabase.DeleteItems(_database.DatabasePath, ids);
        }
        catch (Exception)
        {
        }
        UpdateFilteredItemsSync();
    }

    public void DeleteAllItemsOnDay(DateTime localDay)
    {
        var fromUtc = DateTime.SpecifyKind(localDay.Date, DateTimeKind.Local).ToUniversalTime();
        var toUtc = fromUtc.AddDays(1);
        var ids = Items
            .Where(i => i.CreatedAt >= fromUtc && i.CreatedAt < toUtc)
            .Select(i => i.Id)
            .ToList();
        try
        {
            _database.DeleteCreatedAtRange(fromUtc, toUtc);
        }
        catch (Exception)
        {
        }
        Items.RemoveAll(i => ids.Contains(i.Id));
        UpdateFilteredItemsSync();
    }

    // ---- lan sync upload helper -------------------------------------------------

    public IReadOnlyList<ClipboardItem> ItemsEligibleForDeviceSync() =>
        Items
            .Where(i => i.Source == ClipboardSource.Local
                        && i.Content.Kind == ClipboardContentKind.Text
                        && !string.IsNullOrWhiteSpace(i.Content.Text))
            .ToList();
}
