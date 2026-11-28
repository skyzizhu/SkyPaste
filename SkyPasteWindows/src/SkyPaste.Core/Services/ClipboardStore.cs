using System.Collections.Concurrent;
using System.Diagnostics;
using Microsoft.Data.Sqlite;
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

    public ClipboardStore(ClipboardDatabase database, StatisticsDatabase statistics, AppSettingsService settings,
        Func<ClipboardItem, ClipboardItem>? memoryOptimizer = null)
    {
        _database = database;
        _statistics = statistics;
        _settings = settings;
        MemoryOptimizer = memoryOptimizer;
        _settings.HistoryLimitChanged += ApplyHistoryLimit;

        LoadInitial();
    }

    public string? StartupNotice { get; private set; }

    private void LoadInitial()
    {
        if (_database.RecoveryBackupDirectory is not null)
        {
            StartupNotice = Localization.L10n.T("notice.database_recovered");
        }

        try
        {
            Items = _database.LoadVisibleItems(_settings.HistoryLimit, MemoryOptimizer);
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
        if (SensitiveContentFilter.ShouldExclude(rawItem.TextValue, rawItem.SourceApp, _settings.PrivacyFilteringEnabled))
        {
            return;
        }

        // Inherit favorite state from an existing item with the same fingerprint.
        var existingFavorite = Items.FirstOrDefault(i => i.Fingerprint == rawItem.Fingerprint)?.IsFavorite
                               ?? ReadStoredFavorite(rawItem.Fingerprint);
        if (existingFavorite is not null)
        {
            rawItem.IsFavorite = existingFavorite.Value;
        }

        // Top-of-list duplicate: refresh timestamp only when something meaningful changed.
        if (Items.Count > 0 && Items[0].Fingerprint == rawItem.Fingerprint)
        {
            if (!ShouldRefreshTopItem(Items[0], rawItem))
            {
                return;
            }
            // Mac semantics: the refreshed copy is a NEW item (new id) persisted
            // WITHOUT recording statistics again, and it still notifies upload.
            var refreshed = RecreateWithTimestamp(rawItem, DateTime.UtcNow);
            ReplaceTop(OptimizePersistedItem(refreshed, PersistWithoutStatistic(refreshed)));
            if (refreshed.Source == ClipboardSource.Local)
            {
                OnLocalItemAdded?.Invoke(refreshed);
            }
            return;
        }

        // Mac order: persist the ORIGINAL first, then keep the memory-optimized
        // copy in the list (full resolution lives in SQLite).
        var memoryItem = OptimizePersistedItem(rawItem, Persist(rawItem));
        Items.RemoveAll(i => i.Fingerprint == memoryItem.Fingerprint);
        Items.Insert(0, memoryItem);
        EnforceHistoryLimit();
        UpdateFilteredItemsSync();
        if (memoryItem.Source == ClipboardSource.Local)
        {
            OnLocalItemAdded?.Invoke(rawItem);
        }
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
        var existingFavorite = existing?.IsFavorite
                               ?? ReadStoredFavorite(incoming.Fingerprint);
        if (existingFavorite is not null)
        {
            incoming.IsFavorite = existingFavorite.Value;
        }
        var item = OptimizePersistedItem(incoming, Persist(incoming));
        if (existing is not null)
        {
            Items.Remove(existing);
        }

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
    }

    private static bool ShouldRefreshTopItem(ClipboardItem oldItem, ClipboardItem newItem) =>
        oldItem.Source != newItem.Source
        || oldItem.SourceApp != newItem.SourceApp
        || oldItem.DeviceName != newItem.DeviceName
        || oldItem.Title != newItem.Title
        || oldItem.Subtitle != newItem.Subtitle
        || oldItem.IsFavorite != newItem.IsFavorite;

    private static ClipboardItem RecreateWithTimestamp(ClipboardItem item, DateTime utcNow)
    {
        // Mac: the refreshed copy is a NEW decoded item (new UUID) persisted
        // via remove-by-fingerprint + insert.
        var replacement = new ClipboardItem(
            Guid.NewGuid(), utcNow, item.Content, item.Fingerprint, item.Source, item.SourceApp ?? (item.DeviceName is null ? null : new ClipboardSourceApp("device", item.DeviceName)), item.IsFavorite);
        return replacement;
    }

    private bool? ReadStoredFavorite(string fingerprint)
    {
        try
        {
            return _database.FavoriteStateForFingerprint(fingerprint);
        }
        catch (SqliteException error)
        {
            Debug.WriteLine($"Clipboard favorite lookup failed: {error.SqliteErrorCode}");
            return null;
        }
    }

    private bool Persist(ClipboardItem item)
    {
        var saved = PersistWithoutStatistic(item);
        try
        {
            _statistics.Record(item);
        }
        catch (SqliteException error)
        {
            Debug.WriteLine($"Clipboard statistics write failed: {error.SqliteErrorCode}");
            return saved;
        }
        StatisticsChanged?.Invoke();
        return saved;
    }

    private bool PersistWithoutStatistic(ClipboardItem item)
    {
        try
        {
            _database.Save(item, _settings.HistoryLimit);
            return true;
        }
        catch (SqliteException error)
        {
            Debug.WriteLine($"Clipboard history write failed: {error.SqliteErrorCode}");
            return false;
        }
    }

    private ClipboardItem OptimizePersistedItem(ClipboardItem item, bool saved) =>
        saved ? MemoryOptimizer?.Invoke(item) ?? item : item;

    // ---- list management ---------------------------------------------------

    private void ReplaceTop(ClipboardItem item)
    {
        Items[0] = item;
        UpdateFilteredItemsSync();
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
                .GroupBy(app => app.ProcessId, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.FirstOrDefault(app => app.ExecutablePath is not null) ?? group.First())
                .OrderBy(app => app.Name, StringComparer.CurrentCultureIgnoreCase)
                .Select(app => new ClipboardSourceAppOption(app.ProcessId, app.Name, app.ExecutablePath))
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

    public bool IsFavorite(ClipboardItem item) =>
        Items.FirstOrDefault(candidate => candidate.Id == item.Id)?.IsFavorite ?? item.IsFavorite;

    public void SetFavorite(ClipboardItem item, bool favorite)
    {
        var visibleItem = Items.FirstOrDefault(candidate => candidate.Id == item.Id);
        if (visibleItem is null)
        {
            return;
        }
        try
        {
            _database.SetFavorite(item.Id, favorite);
        }
        catch (Exception)
        {
            return;
        }
        visibleItem.IsFavorite = item.IsFavorite = favorite;
        if (!favorite)
        {
            try
            {
                _database.TrimToLimit(_settings.HistoryLimit);
            }
            catch (Exception)
            {
            }
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
            // Mac: trimming happens only when UN-favoriting.
            ClipboardDatabase.SetFavorites(_database.DatabasePath, ids, favorite,
                favorite ? null : _settings.HistoryLimit);
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
        // Mac deletes exactly the VISIBLE day's items by id; rows beyond the
        // history limit must survive.
        var ids = Items
            .Where(i => i.CreatedAt >= fromUtc && i.CreatedAt < toUtc)
            .Select(i => i.Id)
            .ToList();
        try
        {
            ClipboardDatabase.DeleteItems(_database.DatabasePath, ids);
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
            .OrderBy(i => i.CreatedAt)
            .ToList();
}
