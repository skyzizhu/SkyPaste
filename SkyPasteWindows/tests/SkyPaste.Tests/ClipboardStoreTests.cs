using SkyPaste.Core.Core;
using SkyPaste.Core.Data;
using SkyPaste.Core.Models;
using SkyPaste.Core.Services;
using Xunit;

namespace SkyPaste.Tests;

public class ClipboardStoreTests : IDisposable
{
    private readonly DatabaseFixture _fixture = new();

    private (ClipboardStore Store, AppSettingsService Settings) MakeStore(int historyLimit = 5)
    {
        var settings = new AppSettingsService(_fixture.Directory);
        settings.HistoryLimit = historyLimit;
        var store = new ClipboardStore(
            new ClipboardDatabase(_fixture.HistoryPath),
            new StatisticsDatabase(_fixture.StatisticsPath),
            settings);
        return (store, settings);
    }

    public void Dispose() => _fixture.Dispose();

    [Fact]
    public void AddInsertsAtHeadAndDedupes()
    {
        var (store, _) = MakeStore();
        store.Add(TestItems.Text("first"));
        store.Add(TestItems.Text("second"));
        Assert.Equal(2, store.Items.Count);
        Assert.Equal("second", store.Items[0].TextValue);

        // Re-add identical content while it is already on top -> unchanged.
        store.Add(TestItems.Text("second"));
        Assert.Equal(2, store.Items.Count);
        Assert.Equal("second", store.Items[0].TextValue);
    }

    [Fact]
    public void ReCopiedContentBumpsToTop()
    {
        var (store, _) = MakeStore();
        store.Add(TestItems.Text("older", DateTime.UtcNow.AddMinutes(-2)));
        store.Add(TestItems.Text("newer", DateTime.UtcNow.AddMinutes(-1)));
        store.Add(TestItems.Text("older", DateTime.UtcNow));
        Assert.Equal(2, store.Items.Count);
        Assert.Equal("older", store.Items[0].TextValue);
    }

    [Fact]
    public void ReCopyFromAnotherAppRefreshesTheSourceOnce()
    {
        var (store, _) = MakeStore();
        var listChanges = 0;
        var statisticsChanges = 0;
        store.ItemsChanged += () => listChanges++;
        store.StatisticsChanged += () => statisticsChanges++;

        store.Add(TestItems.Text("same text", app: new ClipboardSourceApp("first.exe", "First")));
        var latestApp = new ClipboardSourceApp("second.exe", "Second");
        store.Add(TestItems.Text("same text", app: latestApp));

        Assert.Equal(latestApp, Assert.Single(store.Items).SourceApp);
        var database = new ClipboardDatabase(_fixture.HistoryPath);
        Assert.Equal(latestApp, Assert.Single(database.LoadVisibleItems(20)).SourceApp);
        Assert.Equal(2, listChanges);
        Assert.Equal(1, statisticsChanges);
    }

    [Fact]
    public void ReopenedImageHistoryKeepsPreviewsAndRestoresOriginalsOnDemand()
    {
        var (store, settings) = MakeStore();
        var original = new byte[] { 1, 2, 3, 4 };
        var preview = new byte[] { 5, 6 };
        store.Add(TestItems.Image(original));

        var reopened = new ClipboardStore(
            new ClipboardDatabase(_fixture.HistoryPath),
            new StatisticsDatabase(_fixture.StatisticsPath),
            settings,
            item => new ClipboardItem(item.Id, item.CreatedAt, item.Content.WithPreviewOnly(preview),
                item.Fingerprint, item.Source, item.SourceApp, item.IsFavorite));

        var listed = Assert.Single(reopened.Items);
        Assert.True(listed.Content.PreviewOnly);
        Assert.Equal(preview, listed.Content.ImageData);
        Assert.Equal(original, reopened.RestoreFullResolutionItem(listed).Content.ImageData);
    }

    [Fact]
    public void FavoriteStateInheritedOnRecopy()
    {
        var (store, _) = MakeStore();
        store.Add(TestItems.Text("pinned"));
        store.SetFavorite(store.Items[0], true);
        Assert.True(store.Items[0].IsFavorite);

        // Simulate an app restart over the same database: the row keeps is_favorite.
        var reopenedStore = new ClipboardStore(
            new ClipboardDatabase(_fixture.HistoryPath),
            new StatisticsDatabase(_fixture.StatisticsPath),
            new AppSettingsService(_fixture.Directory));
        Assert.Contains(reopenedStore.Items, i => i.IsFavorite);

        // Re-copying the same text inherits the favorite state.
        reopenedStore.Add(TestItems.Text("pinned"));
        Assert.True(reopenedStore.Items[0].IsFavorite);
    }

    [Fact]
    public void FavoriteFromSeparatePreviewUpdatesVisibleItemAndFavoriteFilter()
    {
        var (store, _) = MakeStore();
        store.Add(TestItems.Text("favorite from preview"));
        var item = Assert.Single(store.Items);
        var preview = new ClipboardItem(item.Id, item.CreatedAt, item.Content, item.Fingerprint,
            item.Source, item.SourceApp, item.IsFavorite);

        store.SetFavorite(preview, true);
        Assert.True(item.IsFavorite);
        Assert.True(preview.IsFavorite);
        Assert.Same(item, Assert.Single(store.FilteredItemsByFilter[ClipboardFilter.Favorites]));

        store.SetFavorite(preview, false);
        Assert.False(item.IsFavorite);
        Assert.Empty(store.FilteredItemsByFilter[ClipboardFilter.Favorites]);
    }

    [Fact]
    public void HistoryLimitKeepsFavorites()
    {
        var (store, _) = MakeStore(historyLimit: 20);
        for (var i = 0; i < 22; i++)
        {
            store.Add(TestItems.Text($"item {i}", DateTime.UtcNow.AddSeconds(-i)));
        }
        Assert.Equal(20, store.Items.Count); // oldest two dropped

        // Favorites survive trimming even when they are old.
        store.Add(TestItems.Text("pinned", DateTime.UtcNow.AddDays(-1)));
        store.SetFavorite(store.Items.First(i => i.TextValue == "pinned"), true);
        for (var i = 0; i < 5; i++)
        {
            store.Add(TestItems.Text($"extra {i}"));
        }
        Assert.Contains(store.Items, i => i.IsFavorite && i.TextValue == "pinned");
    }

    [Fact]
    public void DeviceItemNewerWins()
    {
        var (store, _) = MakeStore();
        store.AddDeviceSyncedItem(MakeDeviceItem("from phone", DateTime.UtcNow.AddMinutes(-1)));
        Assert.Single(store.Items);

        // Same text, older timestamp -> ignored.
        store.AddDeviceSyncedItem(MakeDeviceItem("from phone", DateTime.UtcNow.AddMinutes(-2)));
        Assert.Single(store.Items);

        // Different text -> added.
        store.AddDeviceSyncedItem(MakeDeviceItem("second", DateTime.UtcNow));
        Assert.Equal(2, store.Items.Count);
    }

    [Fact]
    public void PrivacyFilterBlocksAdd()
    {
        var (store, settings) = MakeStore();
        settings.PrivacyFilteringEnabled = true;
        store.Add(TestItems.Text("4111 1111 1111 1111"));
        Assert.Empty(store.Items);
        store.Add(TestItems.Text("normal note"));
        Assert.Single(store.Items);
    }

    [Fact]
    public void BatchDeleteAndDayDelete()
    {
        var (store, _) = MakeStore();
        var a = TestItems.Text("a", DateTime.UtcNow);
        var b = TestItems.Text("b", DateTime.UtcNow.AddDays(-3));
        store.Add(a);
        store.Add(b);

        store.DeleteItems(new[] { a.Id });
        Assert.Single(store.Items);

        store.DeleteAllItemsOnDay(DateTime.Now.AddDays(-3));
        Assert.Empty(store.Items);
    }

    [Fact]
    public void FilteredBucketsBuilt()
    {
        var (store, _) = MakeStore();
        store.Add(TestItems.Text("plain words"));
        store.Add(TestItems.Text("https://example.com"));
        var buckets = store.FilteredItemsByFilter;
        Assert.Equal(2, buckets[ClipboardFilter.All].Count);
        // URL items are not plain text, so the text bucket holds only the plain note.
        Assert.Equal(1, buckets[ClipboardFilter.Text].Count);
        Assert.Equal(1, buckets[ClipboardFilter.Url].Count);
    }

    [Fact]
    public void EligibleForDeviceSyncOnlyLocalText()
    {
        var (store, _) = MakeStore();
        store.Add(TestItems.Text("local text"));
        store.AddDeviceSyncedItem(MakeDeviceItem("phone text", DateTime.UtcNow));
        store.Add(TestItems.Image(new byte[] { 1, 2, 3 }));
        var eligible = store.ItemsEligibleForDeviceSync();
        Assert.Single(eligible);
        Assert.Equal("local text", eligible[0].TextValue);
    }

    private static ClipboardItem MakeDeviceItem(string text, DateTime createdAtUtc) =>
        new(Guid.NewGuid(), createdAtUtc,
            ClipboardContent.FromText(text), Fingerprint.ForText(text),
            ClipboardSource.LanDevice, new ClipboardSourceApp("device:Pixel", "Pixel"));
}
