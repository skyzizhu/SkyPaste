using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Windows;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;

namespace SkyPaste.Services;

/// <summary>
/// Port of the macOS drag-out support: images are materialized into a temp
/// file under %TEMP%\SkyPasteDragItems (48h cleanup), files reference their
/// original paths, and OLE DoDragDrop performs the drag.
/// </summary>
public static class DragOutService
{
    public static bool CanDrag(ClipboardItem item) => item.IsImage || item.IsFileCollection;

    /// <summary>Builds the drop payload; returns null when files are missing (caller warns).</summary>
    public static DataObject? BuildDataObject(ClipboardItem item)
    {
        if (item.IsImage)
        {
            var path = MaterializeImage(item);
            if (path is null)
            {
                return null;
            }
            return CreateFileDropObject(new[] { path });
        }

        var files = (item.Content.FilePaths ?? Array.Empty<string>()).Where(File.Exists).ToList();
        if (files.Count == 0)
        {
            return null;
        }
        return CreateFileDropObject(files);
    }

    /// <summary>Returns the list of missing paths for the warning sheet.</summary>
    public static IReadOnlyList<string> MissingFiles(ClipboardItem item) =>
        (item.Content.FilePaths ?? Array.Empty<string>()).Where(p => !File.Exists(p)).ToList();

    public static DragDropEffects StartDrag(DependencyObject dragSource, DataObject data) =>
        System.Windows.DragDrop.DoDragDrop(dragSource, data, DragDropEffects.Copy);

    public static void CleanupTempDirectory()
    {
        try
        {
            var dir = TempDirectory;
            if (!Directory.Exists(dir))
            {
                return;
            }
            var cutoff = DateTime.Now.AddHours(-48);
            foreach (var file in Directory.GetFiles(dir))
            {
                if (File.GetLastWriteTime(file) < cutoff)
                {
                    File.Delete(file);
                }
            }
        }
        catch (Exception)
        {
        }
    }

    private static string TempDirectory =>
        Path.Combine(Path.GetTempPath(), "SkyPasteDragItems");

    private static string? MaterializeImage(ClipboardItem item)
    {
        try
        {
            Directory.CreateDirectory(TempDirectory);
            var data = item.Content.ImageData ?? Array.Empty<byte>();
            if (data.Length == 0)
            {
                return null;
            }
            var baseName = SanitizeFileName(string.IsNullOrWhiteSpace(item.Content.ImageName)
                ? L10n.T("clipboard.image_fallback_name")
                : item.Content.ImageName!);
            var fileName = $"{baseName}-{Guid.NewGuid():N}.png";
            var path = Path.Combine(TempDirectory, fileName);
            File.WriteAllBytes(path, data);
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string SanitizeFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var clean = new string(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim();
        return clean.Length == 0 ? "image" : clean;
    }

    private static DataObject CreateFileDropObject(IReadOnlyList<string> paths)
    {
        var files = new StringCollection();
        foreach (var path in paths)
        {
            files.Add(path);
        }
        var dataObject = new DataObject();
        dataObject.SetFileDropList(files);
        dataObject.SetData("Preferred DropEffect", BitConverter.GetBytes(2));
        return dataObject;
    }
}

/// <summary>Save As / choose-folder dialogs (NSSavePanel equivalents).</summary>
public static class SaveAsService
{
    public static bool SaveImage(Window? owner, ClipboardItem item)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = L10n.T("save_as.title"),
            FileName = SuggestImageName(item),
            Filter = "PNG|*.png|JPEG|*.jpg;*.jpeg",
            AddExtension = true,
        };
        if (dialog.ShowDialog(owner) != true)
        {
            return false;
        }
        try
        {
            var data = item.Content.ImageData ?? Array.Empty<byte>();
            File.WriteAllBytes(dialog.FileName, data);
            return true;
        }
        catch (Exception)
        {
            WarnSaveFailed();
            return false;
        }
    }

    public static bool SaveSingleFile(Window? owner, string sourcePath)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = L10n.T("save_as.title"),
            FileName = Path.GetFileName(sourcePath),
            AddExtension = true,
        };
        if (dialog.ShowDialog(owner) != true)
        {
            return false;
        }
        try
        {
            File.Copy(sourcePath, dialog.FileName, overwrite: true);
            return true;
        }
        catch (Exception)
        {
            WarnSaveFailed();
            return false;
        }
    }

    public static bool SaveMultipleFiles(Window? owner, IReadOnlyList<string> sourcePaths)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = L10n.T("save_as.title"),
            ShowNewFolderButton = true,
        };
        if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK)
        {
            return false;
        }
        try
        {
            foreach (var source in sourcePaths.Where(File.Exists))
            {
                var destination = Path.Combine(dialog.SelectedPath, Path.GetFileName(source));
                destination = EnsureUnique(destination);
                File.Copy(source, destination, overwrite: false);
            }
            return true;
        }
        catch (Exception)
        {
            WarnSaveFailed();
            return false;
        }
    }

    private static string SuggestImageName(ClipboardItem item)
    {
        var name = item.Content.ImageName;
        if (string.IsNullOrWhiteSpace(name) || !Path.HasExtension(name))
        {
            name = (name is { Length: > 0 } ? name : "image") + ".png";
        }
        return SanitizeFileNameForSave(name);
    }

    private static string SanitizeFileNameForSave(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        return new string(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray());
    }

    private static string EnsureUnique(string path)
    {
        if (!File.Exists(path))
        {
            return path;
        }
        var directory = Path.GetDirectoryName(path) ?? ".";
        var name = Path.GetFileNameWithoutExtension(path);
        var extension = Path.GetExtension(path);
        for (var i = 1; i < 1000; i++)
        {
            var candidate = Path.Combine(directory, $"{name} copy {i}{extension}");
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }
        return Path.Combine(directory, $"{name}-{Guid.NewGuid():N}{extension}");
    }

    private static void WarnSaveFailed()
    {
        MessageBox.Show(
            L10n.T("save_as.error_title"),
            "SkyPaste",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
    }
}
