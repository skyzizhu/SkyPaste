using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using SkyPaste.Core.Models;

namespace SkyPaste.Core.Data;

/// <summary>
/// Port of macOS ClipboardDatabase: single table, UNIQUE fingerprint dedup
/// (delete-then-insert so re-copying bumps an item to the top), favorites are
/// never trimmed, WAL journaling, quick_check corruption detection.
/// </summary>
public sealed class ClipboardDatabase
{
    private readonly string _path;

    public ClipboardDatabase(string path)
    {
        _path = path;
        RecoveryBackupDirectory = RecoverIfCorrupted(path);
        using var connection = Open();
        Initialize(connection);
    }

    /// <summary>Absolute path of the backing SQLite file.</summary>
    public string DatabasePath => _path;

    public string? RecoveryBackupDirectory { get; }

    public static string DefaultPath =>
        Path.Combine(Services.AppSettingsService.DefaultDirectory, "history.sqlite");

    private SqliteConnection Open()
    {
        // Pooling disabled: pooled handles keep pointing at moved/deleted files
        // after corruption recovery, and this app opens few long-lived queries anyway.
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = _path,
            Pooling = false,
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
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                kind INTEGER NOT NULL,
                text_value TEXT,
                blob_value BLOB,
                image_name TEXT,
                file_urls_json TEXT,
                pasteboard_payload BLOB,
                fingerprint TEXT NOT NULL UNIQUE,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                is_snippet INTEGER NOT NULL DEFAULT 0,
                source_kind INTEGER NOT NULL DEFAULT 0,
                source_app_bundle_id TEXT,
                source_app_name TEXT,
                source_app_executable_path TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_clipboard_created_at ON clipboard_items(created_at DESC);
            """;
        command.ExecuteNonQuery();

        using var migration = connection.BeginTransaction();
        command.Transaction = migration;
        command.CommandText = "SELECT count(*) FROM pragma_table_info('clipboard_items') WHERE name = 'source_app_executable_path'";
        if ((long)command.ExecuteScalar()! == 0)
        {
            command.CommandText = "ALTER TABLE clipboard_items ADD COLUMN source_app_executable_path TEXT";
            command.ExecuteNonQuery();
        }
        migration.Commit();
    }

    // ---- read -------------------------------------------------------------

    public List<ClipboardItem> LoadVisibleItems(int historyLimit, Func<ClipboardItem, ClipboardItem>? optimize = null)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT * FROM clipboard_items
            WHERE is_favorite = 1
               OR id IN (
                    SELECT id FROM clipboard_items
                    WHERE is_favorite = 0
                    ORDER BY created_at DESC
                    LIMIT $limit
               )
            ORDER BY created_at DESC
            """;
        command.Parameters.AddWithValue("$limit", historyLimit);
        using var reader = command.ExecuteReader();
        return DecodeRows(reader, optimize);
    }

    public ClipboardItem? LoadItem(Guid id)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT * FROM clipboard_items WHERE id = $id";
        command.Parameters.AddWithValue("$id", id.ToString());
        using var reader = command.ExecuteReader();
        return DecodeRows(reader).FirstOrDefault();
    }

    private static List<ClipboardItem> DecodeRows(SqliteDataReader reader, Func<ClipboardItem, ClipboardItem>? optimize = null)
    {
        var items = new List<ClipboardItem>();
        while (reader.Read())
        {
            try
            {
                var item = DecodeRow(reader);
                if (item is not null)
                {
                    items.Add(optimize?.Invoke(item) ?? item);
                }
            }
            catch (Exception)
            {
                // Skip malformed rows (mirrors the macOS skip-on-decode-failure).
            }
        }
        return items;
    }

    private static ClipboardItem? DecodeRow(SqliteDataReader reader)
    {
        var id = reader.GetString(reader.GetOrdinal("id"));
        if (!Guid.TryParse(id, out var guid))
        {
            return null;
        }
        var createdAtSeconds = reader.GetDouble(reader.GetOrdinal("created_at"));
        var createdAt = DateTimeOffset.FromUnixTimeMilliseconds((long)(createdAtSeconds * 1000)).UtcDateTime;
        var kind = reader.GetInt64(reader.GetOrdinal("kind"));
        var fingerprint = reader.GetString(reader.GetOrdinal("fingerprint"));
        var favorite = reader.GetInt64(reader.GetOrdinal("is_favorite")) != 0;
        var sourceKind = (ClipboardSource)reader.GetInt64(reader.GetOrdinal("source_kind"));
        var bundleId = reader.IsDBNull(reader.GetOrdinal("source_app_bundle_id"))
            ? null
            : reader.GetString(reader.GetOrdinal("source_app_bundle_id"));
        var appName = reader.IsDBNull(reader.GetOrdinal("source_app_name"))
            ? null
            : reader.GetString(reader.GetOrdinal("source_app_name"));

        ClipboardContent content;
        switch (kind)
        {
            case 0:
            {
                var text = reader.IsDBNull(reader.GetOrdinal("text_value"))
                    ? string.Empty
                    : reader.GetString(reader.GetOrdinal("text_value"));
                content = ClipboardContent.FromText(text);
                break;
            }
            case 1:
            {
                var blobOrdinal = reader.GetOrdinal("blob_value");
                // A null buffer asks GetBytes for the total field length.
                var length = reader.GetBytes(blobOrdinal, 0, null, 0, 0);
                var data = new byte[length];
                if (length > 0)
                {
                    length = reader.GetBytes(blobOrdinal, 0, data, 0, data.Length);
                }
                var imageName = reader.IsDBNull(reader.GetOrdinal("image_name"))
                    ? null
                    : reader.GetString(reader.GetOrdinal("image_name"));
                content = ClipboardContent.FromImage(data, imageName, length, previewOnly: false);
                break;
            }
            case 2:
            {
                var json = reader.IsDBNull(reader.GetOrdinal("file_urls_json"))
                    ? "[]"
                    : reader.GetString(reader.GetOrdinal("file_urls_json"));
                var paths = JsonSerializer.Deserialize<List<string>>(json) ?? new List<string>();
                content = ClipboardContent.FromFileRefs(paths);
                break;
            }
            default:
                return null;
        }

        ClipboardSourceApp? sourceApp = null;
        if (sourceKind == ClipboardSource.Local && !string.IsNullOrEmpty(bundleId) && !string.IsNullOrEmpty(appName))
        {
            var pathColumn = reader.GetOrdinal("source_app_executable_path");
            var executablePath = reader.IsDBNull(pathColumn) ? null : reader.GetString(pathColumn);
            sourceApp = new ClipboardSourceApp(bundleId, appName, executablePath);
        }

        return new ClipboardItem(guid, createdAt, content, fingerprint, sourceKind, sourceApp, favorite);
    }

    // ---- write ------------------------------------------------------------

    public void Save(ClipboardItem item, int maxItems)
    {
        using var connection = Open();
        using (var transaction = connection.BeginTransaction())
        {
            RemoveByFingerprint(connection, transaction, item.Fingerprint);
            Insert(connection, transaction, item);
            Trim(connection, transaction, maxItems);
            transaction.Commit();
        }
    }

    private static void RemoveByFingerprint(SqliteConnection connection, SqliteTransaction transaction, string fingerprint)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "DELETE FROM clipboard_items WHERE fingerprint = $fp";
        command.Parameters.AddWithValue("$fp", fingerprint);
        command.ExecuteNonQuery();
    }

    private static void Insert(SqliteConnection connection, SqliteTransaction transaction, ClipboardItem item)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO clipboard_items
                (id, created_at, kind, text_value, blob_value, image_name, file_urls_json,
                 pasteboard_payload, fingerprint, is_favorite, is_snippet, source_kind,
                 source_app_bundle_id, source_app_name, source_app_executable_path)
            VALUES
                ($id, $created_at, $kind, $text_value, $blob_value, $image_name, $file_urls_json,
                 NULL, $fingerprint, $is_favorite, $is_snippet, $source_kind,
                 $source_app_bundle_id, $source_app_name, $source_app_executable_path)
            """;
        command.Parameters.AddWithValue("$id", item.Id.ToString());
        command.Parameters.AddWithValue(
            "$created_at",
            (double)new DateTimeOffset(DateTime.SpecifyKind(item.CreatedAt, DateTimeKind.Utc)).ToUnixTimeMilliseconds() / 1000.0);
        command.Parameters.AddWithValue("$kind", (long)item.Content.Kind);
        command.Parameters.AddWithValue("$fingerprint", item.Fingerprint);
        command.Parameters.AddWithValue("$is_favorite", item.IsFavorite ? 1L : 0L);
        command.Parameters.AddWithValue("$is_snippet", 0L);
        command.Parameters.AddWithValue("$source_kind", (long)item.Source);
        command.Parameters.AddWithValue("$source_app_executable_path", (object?)item.SourceApp?.ExecutablePath ?? DBNull.Value);

        switch (item.Content.Kind)
        {
            case ClipboardContentKind.Text:
                command.Parameters.AddWithValue("$text_value", item.Content.Text ?? string.Empty);
                command.Parameters.AddWithValue("$blob_value", DBNull.Value);
                command.Parameters.AddWithValue("$image_name", DBNull.Value);
                command.Parameters.AddWithValue("$file_urls_json", DBNull.Value);
                break;
            case ClipboardContentKind.Image:
                command.Parameters.AddWithValue("$text_value", DBNull.Value);
                command.Parameters.AddWithValue("$blob_value", item.Content.ImageData ?? Array.Empty<byte>());
                command.Parameters.AddWithValue("$image_name", (object?)item.Content.ImageName ?? DBNull.Value);
                command.Parameters.AddWithValue("$file_urls_json", DBNull.Value);
                break;
            case ClipboardContentKind.FileRefs:
                command.Parameters.AddWithValue("$text_value", DBNull.Value);
                command.Parameters.AddWithValue("$blob_value", DBNull.Value);
                command.Parameters.AddWithValue("$image_name", DBNull.Value);
                command.Parameters.AddWithValue(
                    "$file_urls_json",
                    JsonSerializer.Serialize(item.Content.FilePaths ?? Array.Empty<string>()));
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(item));
        }

        if (item.SourceApp is { } app)
        {
            command.Parameters.AddWithValue("$source_app_bundle_id", app.ProcessId);
            command.Parameters.AddWithValue("$source_app_name", app.Name);
        }
        else
        {
            command.Parameters.AddWithValue("$source_app_bundle_id", DBNull.Value);
            command.Parameters.AddWithValue("$source_app_name", DBNull.Value);
        }

        command.ExecuteNonQuery();
    }

    private static void Trim(SqliteConnection connection, SqliteTransaction transaction, int maxItems)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            DELETE FROM clipboard_items
            WHERE is_favorite = 0
              AND id NOT IN (
                    SELECT id FROM clipboard_items
                    WHERE is_favorite = 0
                    ORDER BY created_at DESC
                    LIMIT $limit
              )
            """;
        command.Parameters.AddWithValue("$limit", maxItems);
        command.ExecuteNonQuery();
    }

    public void TrimToLimit(int maxItems)
    {
        using var connection = Open();
        using var transaction = connection.BeginTransaction();
        Trim(connection, transaction, maxItems);
        transaction.Commit();
    }

    public void DeleteItem(Guid id)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM clipboard_items WHERE id = $id";
        command.Parameters.AddWithValue("$id", id.ToString());
        command.ExecuteNonQuery();
    }

    public static void DeleteItems(string databasePath, IReadOnlyCollection<Guid> ids)
    {
        if (ids.Count == 0)
        {
            return;
        }
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString());
        connection.Open();
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        var parameters = ids.Select((id, index) => (Value: id.ToString(), Name: $"$id{index}")).ToList();
        command.CommandText = "DELETE FROM clipboard_items WHERE id IN ("
                              + string.Join(", ", parameters.Select(p => p.Name)) + ")";
        foreach (var (value, name) in parameters)
        {
            command.Parameters.AddWithValue(name, value);
        }
        command.ExecuteNonQuery();
        transaction.Commit();
    }

    public void DeleteCreatedAtRange(DateTime fromUtc, DateTime toUtcExclusive)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            DELETE FROM clipboard_items
            WHERE created_at >= $from AND created_at < $to
            """;
        command.Parameters.AddWithValue(
            "$from", (double)new DateTimeOffset(DateTime.SpecifyKind(fromUtc, DateTimeKind.Utc)).ToUnixTimeMilliseconds() / 1000.0);
        command.Parameters.AddWithValue(
            "$to", (double)new DateTimeOffset(DateTime.SpecifyKind(toUtcExclusive, DateTimeKind.Utc)).ToUnixTimeMilliseconds() / 1000.0);
        command.ExecuteNonQuery();
    }

    public bool? FavoriteStateForFingerprint(string fingerprint)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT is_favorite FROM clipboard_items WHERE fingerprint = $fp LIMIT 1";
        command.Parameters.AddWithValue("$fp", fingerprint);
        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            return null;
        }
        return reader.GetInt64(0) != 0;
    }

    public void SetFavorite(Guid id, bool favorite)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "UPDATE clipboard_items SET is_favorite = $fav WHERE id = $id";
        command.Parameters.AddWithValue("$fav", favorite ? 1L : 0L);
        command.Parameters.AddWithValue("$id", id.ToString());
        command.ExecuteNonQuery();
    }

    public static void SetFavorites(
        string databasePath, IReadOnlyCollection<Guid> ids, bool favorite, int? trimLimit)
    {
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString());
        connection.Open();
        using var transaction = connection.BeginTransaction();
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = "UPDATE clipboard_items SET is_favorite = $fav WHERE id IN ("
                                  + string.Join(", ", ids.Select((_, i) => $"$id{i}")) + ")";
            command.Parameters.AddWithValue("$fav", favorite ? 1L : 0L);
            var index = 0;
            foreach (var id in ids)
            {
                command.Parameters.AddWithValue($"$id{index}", id.ToString());
                index += 1;
            }
            command.ExecuteNonQuery();
        }
        if (trimLimit is { } limit)
        {
            Trim(connection, transaction, limit);
        }
        transaction.Commit();
    }

    public void ClearAllSnippets()
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "UPDATE clipboard_items SET is_snippet = 0";
        command.ExecuteNonQuery();
    }

    // ---- corruption -------------------------------------------------------

    public static bool LooksLikeCorruption(Exception exception) =>
        exception is SqliteException { SqliteErrorCode: 11 or 26 }; // SQLITE_CORRUPT or SQLITE_NOTADB

    /// <summary>
    /// Port of macOS recoverCorruptedDatabaseIfNeeded: quick_check, and when it
    /// fails, back up history.sqlite(-wal/-shm) then delete the originals.
    /// Returns the backup directory (or null when healthy).
    /// </summary>
    public static string? RecoverIfCorrupted(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            // Pooling must stay off here: a pooled handle could still reference
            // the inode of a file that was just moved away during recovery.
            using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Pooling = false,
            }.ToString());
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA quick_check(1)";
            var result = command.ExecuteScalar() as string;
            if (string.IsNullOrEmpty(result) || result == "ok")
            {
                return null;
            }
        }
        catch (Exception exception)
        {
            if (!LooksLikeCorruption(exception))
            {
                // Non-corruption failures (locked, missing) are not ours to fix.
                return null;
            }
        }

        var backupDir = Path.Combine(
            Path.GetDirectoryName(path) ?? ".", "RecoveredDatabases");
        Directory.CreateDirectory(backupDir);
        var stamp = $"{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}";
        var moved = new Stack<(string Source, string Backup)>();
        try
        {
            foreach (var suffix in new[] { "-wal", "-shm", "" })
            {
                var source = path + suffix;
                if (File.Exists(source))
                {
                    var destination = Path.Combine(backupDir, Path.GetFileName(source) + $".{stamp}.bak");
                    File.Move(source, destination);
                    moved.Push((source, destination));
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            foreach (var (source, backup) in moved)
            {
                File.Move(backup, source);
            }
            throw;
        }
        return backupDir;
    }
}
