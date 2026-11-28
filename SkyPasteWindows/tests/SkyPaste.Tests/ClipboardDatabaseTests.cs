using SkyPaste.Core.Data;
using SkyPaste.Core.Models;
using Xunit;

namespace SkyPaste.Tests;

public sealed class DatabaseFixture : IDisposable
{
    public string Directory { get; } = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(), "skypaste-tests-" + Guid.NewGuid().ToString("N"));

    public string HistoryPath => System.IO.Path.Combine(Directory, "history.sqlite");
    public string StatisticsPath => System.IO.Path.Combine(Directory, "statistics.sqlite");

    public DatabaseFixture()
    {
        System.IO.Directory.CreateDirectory(Directory);
    }

    public void Dispose()
    {
        try
        {
            System.IO.Directory.Delete(Directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}

public class ClipboardDatabaseTests : IDisposable
{
    private readonly DatabaseFixture _fixture = new();

    public void Dispose() => _fixture.Dispose();

    [Fact]
    public void SaveAndLoadRoundTrip()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        var item = TestItems.Text("hello world", app: new ClipboardSourceApp("notepad.exe", "Notepad"));
        db.Save(item, maxItems: 100);

        var loaded = db.LoadVisibleItems(100);
        Assert.Single(loaded);
        var restored = loaded[0];
        Assert.Equal(item.Id, restored.Id);
        Assert.Equal("hello world", restored.TextValue);
        Assert.Equal(item.Fingerprint, restored.Fingerprint);
        Assert.Equal("Notepad", restored.SourceApp?.Name);
        Assert.Equal("notepad.exe", restored.SourceApp?.ProcessId);
    }

    [Fact]
    public void DuplicateFingerprintBumpsToTop()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        var first = TestItems.Text("same text", DateTime.UtcNow.AddMinutes(-5));
        var second = TestItems.Text("newer text", DateTime.UtcNow.AddMinutes(-1));
        db.Save(first, 100);
        db.Save(second, 100);

        // Re-copy the older text: it should replace the older row and become newest.
        var recopied = TestItems.Text("same text", DateTime.UtcNow);
        db.Save(recopied, 100);

        var loaded = db.LoadVisibleItems(100);
        Assert.Equal(2, loaded.Count);
        Assert.Equal("same text", loaded[0].TextValue);
        Assert.Equal(recopied.Id, loaded[0].Id);
    }

    [Fact]
    public void FavoritesSurviveTrimming()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        for (var i = 0; i < 10; i++)
        {
            db.Save(TestItems.Text($"item {i}", DateTime.UtcNow.AddSeconds(-i)), 5);
        }
        var favorite = TestItems.Text("pinned", DateTime.UtcNow.AddSeconds(-30), favorite: true);
        db.Save(favorite, 5);

        var loaded = db.LoadVisibleItems(5);
        Assert.Contains(loaded, i => i.IsFavorite && i.TextValue == "pinned");
        Assert.Equal(6, loaded.Count); // 5 non-favorites + 1 favorite
    }

    [Fact]
    public void TrimKeepsOnlyNewestNonFavorites()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        for (var i = 0; i < 10; i++)
        {
            db.Save(TestItems.Text($"item {i}", DateTime.UtcNow.AddSeconds(-i)), 3);
        }
        var loaded = db.LoadVisibleItems(3);
        Assert.Equal(3, loaded.Count);
        Assert.All(loaded, i => Assert.False(i.IsFavorite));
    }

    [Fact]
    public void ImageRoundTrip()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        var data = new byte[] { 1, 2, 3, 4, 5 };
        var item = new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromImage(data, "shot.png", 12345, previewOnly: false),
            "img:test", ClipboardSource.Local, null);
        db.Save(item, 10);

        var restored = db.LoadVisibleItems(10)[0];
        Assert.True(restored.IsImage);
        Assert.Equal("shot.png", restored.Content.ImageName);
        Assert.Equal(data, restored.Content.ImageData);
        // macOS semantics: originalByteCount is re-derived from the stored blob length.
        Assert.Equal(data.LongLength, restored.Content.OriginalByteCount);
    }

    [Fact]
    public void FileRefsRoundTrip()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        var item = new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromFileRefs(new[] { @"C:\Temp\a.txt", @"C:\Temp\b.txt" }),
            "file:x", ClipboardSource.Local, null);
        db.Save(item, 10);

        var restored = db.LoadVisibleItems(10)[0];
        Assert.Equal(2, restored.FilePaths!.Count);
        Assert.Equal(@"C:\Temp\a.txt", restored.FilePaths[0]);
    }

    [Fact]
    public void FavoriteStateByFingerprint()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        var item = TestItems.Text("fav text", favorite: true);
        db.Save(item, 10);

        Assert.True(db.FavoriteStateForFingerprint(item.Fingerprint));

        var fresh = TestItems.Text("fav text");
        Assert.True(db.FavoriteStateForFingerprint(fresh.Fingerprint));

        Assert.Null(db.FavoriteStateForFingerprint("txt:never-saved"));
    }

    [Fact]
    public void DeleteItemsAndFavoriteUpdates()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        var a = TestItems.Text("a");
        var b = TestItems.Text("b");
        db.Save(a, 10);
        db.Save(b, 10);

        db.SetFavorite(a.Id, true);
        Assert.True(db.LoadVisibleItems(10).First(i => i.Id == a.Id).IsFavorite);

        ClipboardDatabase.DeleteItems(_fixture.HistoryPath, new[] { b.Id });
        var loaded = db.LoadVisibleItems(10);
        Assert.Single(loaded);
        Assert.Equal(a.Id, loaded[0].Id);
    }

    [Fact]
    public void DeleteCreatedAtRange()
    {
        var db = new ClipboardDatabase(_fixture.HistoryPath);
        var today = TestItems.Text("today", DateTime.UtcNow);
        var old = TestItems.Text("old", DateTime.UtcNow.AddDays(-2));
        db.Save(today, 10);
        db.Save(old, 10);

        var from = DateTime.UtcNow.AddDays(-3);
        var to = DateTime.UtcNow.AddDays(-1);
        db.DeleteCreatedAtRange(from, to);

        var loaded = db.LoadVisibleItems(10);
        Assert.Single(loaded);
        Assert.Equal("today", loaded[0].TextValue);
    }

    [Fact]
    public void OpeningCorruptHistoryBacksItUpAndCreatesAUsableDatabase()
    {
        var corruptBytes = new byte[] { 0x11, 0x22, 0x33, 0x44, 0x55 };
        File.WriteAllBytes(_fixture.HistoryPath, corruptBytes);

        var db = new ClipboardDatabase(_fixture.HistoryPath);
        Assert.NotNull(db.RecoveryBackupDirectory);
        var backup = Assert.Single(Directory.GetFiles(db.RecoveryBackupDirectory));
        Assert.Equal(corruptBytes, File.ReadAllBytes(backup));
        Assert.Empty(db.LoadVisibleItems(20));

        db.Save(TestItems.Text("after recovery"), 20);
        var reopened = new ClipboardDatabase(_fixture.HistoryPath);
        Assert.Null(reopened.RecoveryBackupDirectory);
        Assert.Equal("after recovery", Assert.Single(reopened.LoadVisibleItems(20)).TextValue);
    }
}

public class StatisticsDatabaseTests : IDisposable
{
    private readonly DatabaseFixture _fixture = new();

    public void Dispose() => _fixture.Dispose();

    [Fact]
    public void RecordAccumulates()
    {
        var db = new StatisticsDatabase(_fixture.StatisticsPath);
        var now = DateTime.UtcNow;
        db.Record(TestItems.Text("a", now));
        db.Record(TestItems.Text("b", now.AddMinutes(1)));
        db.Record(TestItems.Text("https://x.com", now.AddMinutes(2)));

        var from = StatisticsDatabase.DayBucket(DateTime.Now.AddHours(-1));
        var to = StatisticsDatabase.DayBucket(DateTime.Now.AddDays(1));
        var daily = db.DailyEntries(from, to);
        Assert.Equal(3, daily.Sum(e => e.Count));
        Assert.Contains(daily, e => e.Category == (int)StatisticsCategory.Text);
        Assert.Contains(daily, e => e.Category == (int)StatisticsCategory.Url);
    }

    [Fact]
    public void CategoryPriority()
    {
        // Use real filesystem paths so Directory.Exists behaves the same everywhere.
        var imageFile = Path.Combine(_fixture.Directory, "photo.png");
        var folder = Path.Combine(_fixture.Directory, "myfolder");
        File.WriteAllBytes(imageFile, new byte[] { 1 });
        Directory.CreateDirectory(folder);

        var imageFileItem = new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromFileRefs(new[] { imageFile }), "file:p", ClipboardSource.Local, null);
        Assert.Equal(StatisticsCategory.File, StatisticsCategoryExtensions.FromItem(imageFileItem));

        var folderItem = new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromFileRefs(new[] { folder }), "file:f", ClipboardSource.Local, null);
        Assert.Equal(StatisticsCategory.Folder, StatisticsCategoryExtensions.FromItem(folderItem));

        var emailItem = TestItems.Text("user@example.com");
        Assert.Equal(StatisticsCategory.Email, StatisticsCategoryExtensions.FromItem(emailItem));

        var codeItem = TestItems.Text("select * from t where x = 1;");
        Assert.Equal(StatisticsCategory.Code, StatisticsCategoryExtensions.FromItem(codeItem));
    }

    [Fact]
    public void AppCountsAggregate()
    {
        var db = new StatisticsDatabase(_fixture.StatisticsPath);
        var app = new ClipboardSourceApp("notepad.exe", "Notepad", @"C:\Windows\notepad.exe");
        db.Record(TestItems.Text("a", DateTime.UtcNow, app: app));
        db.Record(TestItems.Text("b", DateTime.UtcNow, app: app with { ExecutablePath = null }));
        db.Record(TestItems.Text("c", DateTime.UtcNow, app: new ClipboardSourceApp("code.exe", "VS Code")));

        var from = StatisticsDatabase.DayBucket(DateTime.Now.AddHours(-1));
        var to = StatisticsDatabase.DayBucket(DateTime.Now.AddDays(1));
        var apps = db.AppEntries(from, to);
        Assert.Equal(2, apps.Count);
        Assert.Equal(2, apps[0].Count); // ordered by count desc
        Assert.Equal("notepad.exe", apps[0].ProcessId);
        Assert.Equal(app.ExecutablePath, apps[0].ExecutablePath);
        Assert.Null(apps[1].ExecutablePath);
    }

    [Fact]
    public void SeedOnlyRunsOnce()
    {
        var db = new StatisticsDatabase(_fixture.StatisticsPath);
        var now = DateTime.UtcNow;
        var items = new List<ClipboardItem>
        {
            TestItems.Text("seed 1", now.AddDays(-1)),
            TestItems.Text("seed 2", now.AddDays(-2)),
        };
        db.SeedRetainedHistoryIfNeeded(items);

        var from = StatisticsDatabase.DayBucket(DateTime.Now.AddDays(-3));
        var to = StatisticsDatabase.DayBucket(DateTime.Now.AddDays(1));
        Assert.Equal(2, db.DailyEntries(from, to).Sum(e => e.Count));

        // Seeding again must not double-count.
        db.SeedRetainedHistoryIfNeeded(items);
        Assert.Equal(2, db.DailyEntries(from, to).Sum(e => e.Count));
    }

    [Fact]
    public void CorruptStatisticsAreBackedUpAndSeededFromRetainedHistory()
    {
        var corruptBytes = new byte[] { 0x11, 0x22, 0x33, 0x44, 0x55 };
        File.WriteAllBytes(_fixture.StatisticsPath, corruptBytes);

        var database = new StatisticsDatabase(_fixture.StatisticsPath);
        Assert.NotNull(database.RecoveryBackupDirectory);
        var backup = Assert.Single(Directory.GetFiles(database.RecoveryBackupDirectory));
        Assert.Equal(corruptBytes, File.ReadAllBytes(backup));

        var now = DateTime.Now;
        var today = StatisticsDatabase.DayBucket(now);
        database.SeedRetainedHistoryIfNeeded([TestItems.Text("retained", now.ToUniversalTime())]);
        Assert.Equal(1, Assert.Single(database.DailyEntries(today, today + 86400)).Count);
    }
}
