using System.IO;

namespace SkyPaste;

internal sealed record FilePreviewEntry(
    string Path, string Name, bool IsFolder, bool Exists, long? Size, DateTime? Modified)
{
    public string IconGlyph => IsFolder ? "\uE8B7" : "\uE8A5";
    public string DisplaySize => Size is long bytes ? FilePreviewSnapshot.FormatSize(bytes) : "";
}

internal sealed record FilePreviewSnapshot(IReadOnlyList<FilePreviewEntry> Selection, IReadOnlyList<FilePreviewEntry> Contents)
{
    public static FilePreviewSnapshot Build(IReadOnlyList<string> paths, CancellationToken token)
    {
        var selection = paths.Select(path => ReadEntry(path, includeFolderSize: true, token)).ToArray();
        if (selection.Length != 1)
        {
            return new FilePreviewSnapshot(selection, selection);
        }

        var entry = selection[0];
        var contents = entry.Exists && entry.IsFolder
            ? EnumerateContents(entry.Path, token)
            : Array.Empty<FilePreviewEntry>();
        return new FilePreviewSnapshot(selection, contents);
    }

    private static FilePreviewEntry[] EnumerateContents(string directory, CancellationToken token)
    {
        try
        {
            return Directory.EnumerateFileSystemEntries(directory)
                .Select(path => ReadEntry(path, includeFolderSize: false, token))
                .OrderByDescending(entry => entry.IsFolder)
                .ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToArray();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<FilePreviewEntry>();
        }
    }

    private static FilePreviewEntry ReadEntry(string path, bool includeFolderSize, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
        if (string.IsNullOrEmpty(name))
        {
            name = path;
        }
        try
        {
            if (Directory.Exists(path))
            {
                var size = includeFolderSize ? ReadFolderSize(path, token) : (long?)null;
                return new FilePreviewEntry(path, name, true, true, size, null);
            }
            var file = new FileInfo(path);
            if (file.Exists)
            {
                return new FilePreviewEntry(path, name, false, true, file.Length, file.LastWriteTime);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            // A file may be moved, disconnected, or become inaccessible while loading.
        }
        return new FilePreviewEntry(path, name, Path.EndsInDirectorySeparator(path), false, null, null);
    }

    private static long? ReadFolderSize(string path, CancellationToken token)
    {
        try
        {
            var options = new EnumerationOptions
            {
                RecurseSubdirectories = true,
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.ReparsePoint,
            };
            long size = 0;
            foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", options))
            {
                token.ThrowIfCancellationRequested();
                size += file.Length;
            }
            return size;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static string FormatSize(long bytes) =>
        bytes < 1024 ? $"{bytes} B"
            : bytes < 1024 * 1024 ? $"{bytes / 1024.0:0.#} KB"
            : bytes < 1024L * 1024 * 1024 ? $"{bytes / (1024.0 * 1024):0.#} MB"
            : $"{bytes / (1024.0 * 1024 * 1024):0.##} GB";
}
