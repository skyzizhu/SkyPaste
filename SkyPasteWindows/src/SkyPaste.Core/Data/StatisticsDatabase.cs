using Microsoft.Data.Sqlite;
using SkyPaste.Core.Models;

namespace SkyPaste.Core.Data;

public enum StatisticsCategory
{
    Text = 0,
    Image = 1,
    File = 2,
    Folder = 3,
    Code = 4,
    Url = 5,
    Email = 6,
}

public static class StatisticsCategoryExtensions
{
    public static StatisticsCategory FromItem(ClipboardItem item)
    {
        if (item.ContainsFiles)
        {
            return StatisticsCategory.File;
        }
        if (item.ContainsFolders)
        {
            return StatisticsCategory.Folder;
        }
        if (item.IsImage)
        {
            return StatisticsCategory.Image;
        }
        if (item.IsEmail)
        {
            return StatisticsCategory.Email;
        }
        if (item.IsUrl)
        {
            return StatisticsCategory.Url;
        }
        if (item.IsCode)
        {
            return StatisticsCategory.Code;
        }
        return StatisticsCategory.Text;
    }

    public static ClipboardFilter ToFilter(this StatisticsCategory category) =>
        category switch
        {
            StatisticsCategory.Text => ClipboardFilter.Text,
            StatisticsCategory.Image => ClipboardFilter.Image,
            StatisticsCategory.File => ClipboardFilter.File,
            StatisticsCategory.Folder => ClipboardFilter.Folder,
            StatisticsCategory.Code => ClipboardFilter.Code,
            StatisticsCategory.Url => ClipboardFilter.Url,
            StatisticsCategory.Email => ClipboardFilter.Email,
            _ => ClipboardFilter.All,
        };

    public static string LabelKey(this StatisticsCategory category) =>
        category switch
        {
            StatisticsCategory.Text => "filter.text",
            StatisticsCategory.Image => "filter.image",
            StatisticsCategory.File => "filter.file",
            StatisticsCategory.Folder => "filter.folder",
            StatisticsCategory.Code => "filter.code",
            StatisticsCategory.Url => "filter.url",
            StatisticsCategory.Email => "filter.email",
            _ => "filter.all",
        };
}

public sealed record StatisticsCategoryEntry(long Bucket, int Category, long Count);
public sealed record StatisticsAppEntry(string ProcessId, string Name, long Count, string? ExecutablePath = null);

/// <summary>
/// Port of macOS ClipboardStatisticsStore: a separate SQLite file with three
/// pre-aggregated tables (daily / hourly / per-app) plus a metadata table.
/// Hourly buckets only retain the trailing 72 hours.
/// </summary>
public sealed class StatisticsDatabase
{
    public const string SeedDailyKey = "history_seed_v1";
    public const string SeedAppKey = "history_app_seed_v1";
    private static readonly long HourlyRetentionSeconds = 72 * 3600;

    private readonly string _path;

    public StatisticsDatabase(string path)
    {
        _path = path;
        try
        {
            using var connection = Open(pooling: false);
            Initialize(connection);
        }
        catch (SqliteException error) when (ClipboardDatabase.LooksLikeCorruption(error))
        {
            RecoveryBackupDirectory = ClipboardDatabase.RecoverIfCorrupted(path);
            if (RecoveryBackupDirectory is null)
            {
                throw;
            }
            using var connection = Open(pooling: false);
            Initialize(connection);
        }
    }

    public string? RecoveryBackupDirectory { get; }

    public static string DefaultPath =>
        Path.Combine(Services.AppSettingsService.DefaultDirectory, "statistics.sqlite");

    private SqliteConnection Open(bool pooling = true)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = _path,
            Pooling = pooling,
        }.ToString());
        connection.Open();
        return connection;
    }

    private static void Initialize(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS daily_counts (
                bucket INTEGER NOT NULL,
                category INTEGER NOT NULL,
                count INTEGER NOT NULL,
                PRIMARY KEY (bucket, category)
            );
            CREATE TABLE IF NOT EXISTS hourly_counts (
                bucket INTEGER NOT NULL,
                category INTEGER NOT NULL,
                count INTEGER NOT NULL,
                PRIMARY KEY (bucket, category)
            );
            CREATE TABLE IF NOT EXISTS daily_app_counts (
                bucket INTEGER NOT NULL,
                bundle_id TEXT NOT NULL,
                name TEXT NOT NULL,
                executable_path TEXT,
                count INTEGER NOT NULL,
                PRIMARY KEY (bucket, bundle_id)
            );
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """;
        command.ExecuteNonQuery();

        using var migration = connection.BeginTransaction();
        command.Transaction = migration;
        command.CommandText = "SELECT count(*) FROM pragma_table_info('daily_app_counts') WHERE name = 'executable_path'";
        if ((long)command.ExecuteScalar()! == 0)
        {
            command.CommandText = "ALTER TABLE daily_app_counts ADD COLUMN executable_path TEXT";
            command.ExecuteNonQuery();
        }
        migration.Commit();
    }

    public static long DayBucket(DateTime local) =>
        ((DateTimeOffset)DateTime.SpecifyKind(local.Date, DateTimeKind.Local)).ToUnixTimeSeconds();

    public static long HourBucket(DateTime local) =>
        ((DateTimeOffset)new DateTime(local.Year, local.Month, local.Day, local.Hour, 0, 0, DateTimeKind.Local)).ToUnixTimeSeconds();

    public void Record(ClipboardItem item)
    {
        var local = item.CreatedAt.ToLocalTime();
        var dayBucket = DayBucket(local);
        var hourBucket = HourBucket(local);
        var cutoff = DayBucket(DateTime.Now) - HourlyRetentionSeconds;
        var category = (long)StatisticsCategoryExtensions.FromItem(item);

        using var connection = Open();
        using var transaction = connection.BeginTransaction();
        Upsert(connection, transaction, "daily_counts", dayBucket, category);
        if (hourBucket >= cutoff)
        {
            Upsert(connection, transaction, "hourly_counts", hourBucket, category);
        }
        using (var prune = connection.CreateCommand())
        {
            prune.Transaction = transaction;
            prune.CommandText = "DELETE FROM hourly_counts WHERE bucket < $cutoff";
            prune.Parameters.AddWithValue("$cutoff", cutoff);
            prune.ExecuteNonQuery();
        }

        if (item.SourceApp is { } app)
        {
            UpsertApp(connection, transaction, dayBucket, app);
        }
        transaction.Commit();
    }

    private static void UpsertApp(SqliteConnection connection, SqliteTransaction transaction, long bucket, ClipboardSourceApp app)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO daily_app_counts (bucket, bundle_id, name, executable_path, count)
            VALUES ($bucket, $bundle_id, $name, $path, 1)
            ON CONFLICT (bucket, bundle_id) DO UPDATE SET
                name = excluded.name,
                executable_path = COALESCE(excluded.executable_path, executable_path),
                count = count + 1
            """;
        command.Parameters.AddWithValue("$bucket", bucket);
        command.Parameters.AddWithValue("$bundle_id", app.ProcessId);
        command.Parameters.AddWithValue("$name", app.Name);
        command.Parameters.AddWithValue("$path", string.IsNullOrWhiteSpace(app.ExecutablePath) ? DBNull.Value : app.ExecutablePath);
        command.ExecuteNonQuery();
    }

    private static void Upsert(SqliteConnection connection, SqliteTransaction transaction, string table, long bucket, long category)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = $"""
            INSERT INTO {table} (bucket, category, count)
            VALUES ($bucket, $category, 1)
            ON CONFLICT (bucket, category) DO UPDATE SET count = count + 1
            """;
        command.Parameters.AddWithValue("$bucket", bucket);
        command.Parameters.AddWithValue("$category", category);
        command.ExecuteNonQuery();
    }

    /// <summary>
    /// Port of seedRetainedHistoryIfNeeded: on first run, backfill daily and
    /// hourly counts from retained history (only buckets older than anything
    /// already recorded, so live counters are never double-counted).
    /// </summary>
    public void SeedRetainedHistoryIfNeeded(IReadOnlyList<ClipboardItem> items)
    {
        using var connection = Open();
        if (GetMetadata(connection, SeedDailyKey) is not null)
        {
            return;
        }

        var earliestDaily = MinBucket(connection, "daily_counts");
        var earliestHourly = MinBucket(connection, "hourly_counts");
        var hourlyCutoff = DayBucket(DateTime.Now) - HourlyRetentionSeconds;

        using (var transaction = connection.BeginTransaction())
        {
            foreach (var item in items)
            {
                var local = item.CreatedAt.ToLocalTime();
                var dayBucket = DayBucket(local);
                var hourBucket = HourBucket(local);
                var category = (long)StatisticsCategoryExtensions.FromItem(item);
                if (earliestDaily is null || dayBucket < earliestDaily)
                {
                    Upsert(connection, transaction, "daily_counts", dayBucket, category);
                }
                if (hourBucket >= hourlyCutoff
                    && (earliestHourly is null || hourBucket < earliestHourly))
                {
                    Upsert(connection, transaction, "hourly_counts", hourBucket, category);
                }
            }
            transaction.Commit();
        }
        SetMetadata(connection, SeedDailyKey, "1");

        // App counts keep a separate marker + backfill (mirrors history_app_seed_v1).
        if (GetMetadata(connection, SeedAppKey) is null)
        {
            using (var transaction = connection.BeginTransaction())
            {
                var firstAppDay = MinBucket(connection, "daily_app_counts");
                foreach (var item in items)
                {
                    if (item.SourceApp is not { } app)
                    {
                        continue;
                    }
                    var local = item.CreatedAt.ToLocalTime();
                    var dayBucket = DayBucket(local);
                    if (firstAppDay is null || dayBucket < firstAppDay)
                    {
                        UpsertApp(connection, transaction, dayBucket, app);
                    }
                }
                transaction.Commit();
            }
            SetMetadata(connection, SeedAppKey, "1");
        }
    }

    private static long? MinBucket(SqliteConnection connection, string table)
    {
        using var command = connection.CreateCommand();
        command.CommandText = $"SELECT MIN(bucket) FROM {table}";
        var result = command.ExecuteScalar();
        return result is long value ? value : null;
    }

    private static string? GetMetadata(SqliteConnection connection, string key)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT value FROM metadata WHERE key = $key";
        command.Parameters.AddWithValue("$key", key);
        return command.ExecuteScalar() as string;
    }

    private static void SetMetadata(SqliteConnection connection, string key, string value)
    {
        using var command = connection.CreateCommand();
        command.CommandText = """
            INSERT INTO metadata (key, value) VALUES ($key, $value)
            ON CONFLICT (key) DO UPDATE SET value = $value
            """;
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$value", value);
        command.ExecuteNonQuery();
    }

    // ---- queries ----------------------------------------------------------

    public IReadOnlyList<StatisticsCategoryEntry> DailyEntries(long fromBucket, long toBucketExclusive)
    {
        using var connection = Open();
        return Entries(connection, "daily_counts", fromBucket, toBucketExclusive);
    }

    public IReadOnlyList<StatisticsCategoryEntry> HourlyEntries(long fromBucket, long toBucketExclusive)
    {
        using var connection = Open();
        return Entries(connection, "hourly_counts", fromBucket, toBucketExclusive);
    }

    private static IReadOnlyList<StatisticsCategoryEntry> Entries(
        SqliteConnection connection, string table, long fromBucket, long toBucketExclusive)
    {
        using var command = connection.CreateCommand();
        command.CommandText = $"""
            SELECT bucket, category, count FROM {table}
            WHERE bucket >= $from AND bucket < $to
            ORDER BY bucket
            """;
        command.Parameters.AddWithValue("$from", fromBucket);
        command.Parameters.AddWithValue("$to", toBucketExclusive);
        using var reader = command.ExecuteReader();
        var entries = new List<StatisticsCategoryEntry>();
        while (reader.Read())
        {
            entries.Add(new StatisticsCategoryEntry(
                reader.GetInt64(0), (int)reader.GetInt64(1), reader.GetInt64(2)));
        }
        return entries;
    }

    public IReadOnlyList<StatisticsAppEntry> AppEntries(long fromBucket, long toBucketExclusive)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT bundle_id, MAX(name), SUM(count), MAX(executable_path) FROM daily_app_counts
            WHERE bucket >= $from AND bucket < $to
            GROUP BY bundle_id
            ORDER BY SUM(count) DESC, bundle_id
            """;
        command.Parameters.AddWithValue("$from", fromBucket);
        command.Parameters.AddWithValue("$to", toBucketExclusive);
        using var reader = command.ExecuteReader();
        var entries = new List<StatisticsAppEntry>();
        while (reader.Read())
        {
            entries.Add(new StatisticsAppEntry(
                reader.GetString(0), reader.GetString(1), reader.GetInt64(2),
                reader.IsDBNull(3) ? null : reader.GetString(3)));
        }
        return entries;
    }
}
