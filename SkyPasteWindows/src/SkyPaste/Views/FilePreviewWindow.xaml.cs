using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// File/folder preview (mac FileSystemPreviewView): details, directory contents,
/// missing-path banner, and an image-file dual view with preview toggle.
/// </summary>
public partial class FilePreviewWindow : Window
{
    private readonly App _app;
    private readonly ClipboardItem _item;

    public FilePreviewWindow(App app, ClipboardItem item)
    {
        InitializeComponent();
        _app = app;
        _item = item;
        Title = L10n.T("preview.file_system_title");
        PreviewTitle.Text = L10n.T("preview.file_system_title");
        Width = 880;
        Height = 660;
        MinWidth = 700;
        MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        Background = (Brush)FindResource("Window.Background");

        CopyLabel.Text = L10n.T("menu.copy");
        SaveAsLabel.Text = L10n.T("menu.save_as");
        CopyPathLabel.Text = L10n.T("menu.copy_path");
        RevealLabel.Text = L10n.T("menu.reveal_in_explorer");
        OpenLabel.Text = item.OpenActionTitle;
        FavoriteLabel.Text = item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");

        if (item.IsSingleImageFile)
        {
            ToggleImageMode.Visibility = Visibility.Visible;
            ToggleImageModeLabel.Text = L10n.T("preview.file_system_show_image");
        }
        else
        {
            ToggleImageMode.Visibility = Visibility.Collapsed;
        }

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };

        Loaded += (_, _) => BuildDetails();
    }

    private void BuildDetails()
    {
        InfoHost.Children.Clear();
        var paths = _item.Content.FilePaths ?? Array.Empty<string>();
        var missing = paths.Where(p => !File.Exists(p) && !Directory.Exists(p)).ToList();

        if (missing.Count > 0)
        {
            var banner = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(40, 0xE0, 0xA3, 0x29)),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12, 8, 12, 8),
                Margin = new Thickness(0, 0, 0, 12),
                Child = new StackPanel
                {
                    Children =
                    {
                        new TextBlock
                        {
                            Text = L10n.T("preview.file_system_not_found"),
                            FontSize = 12,
                            FontWeight = FontWeights.SemiBold,
                            Foreground = (Brush)FindResource("Text.Primary"),
                        },
                        new TextBlock
                        {
                            Text = string.Join("\n", missing),
                            FontSize = 11,
                            FontFamily = new FontFamily("Consolas, monospace"),
                            Foreground = (Brush)FindResource("Text.Secondary"),
                            TextWrapping = TextWrapping.Wrap,
                            Margin = new Thickness(0, 4, 0, 0),
                        },
                    },
                },
            };
            InfoHost.Children.Add(banner);
        }

        foreach (var path in paths.Where(p => File.Exists(p) || Directory.Exists(p)))
        {
            var info = new DirectoryInfo(path) switch
            {
                _ when Directory.Exists(path) => CollectDirectoryInfo(path),
                _ => CollectFileInfo(path),
            };
            InfoHost.Children.Add(BuildInfoCard(info));
            if (Directory.Exists(path))
            {
                InfoHost.Children.Add(BuildContentsCard(path));
            }
        }
    }

    private List<(string Label, string Value)> CollectFileInfo(string path)
    {
        var file = new FileInfo(path);
        var rows = new List<(string, string)>
        {
            (L10n.T("preview.file_system_label_name"), file.Name),
            (L10n.T("preview.file_system_label_type"), L10n.T("preview.file_system_type_file")),
        };
        var ext = file.Extension.TrimStart('.');
        if (ext.Length > 0)
        {
            rows.Add((L10n.T("preview.file_system_label_extension"), ext.ToUpperInvariant()));
        }
        rows.Add((L10n.T("preview.file_system_label_size"), FormatBytes(file.Length)));
        rows.Add((L10n.T("preview.file_system_label_modified"), file.LastWriteTime.ToString("yyyy-MM-dd HH:mm")));
        rows.Add((L10n.T("preview.file_system_label_path"), path));
        return rows;
    }

    private List<(string Label, string Value)> CollectDirectoryInfo(string path)
    {
        var directory = new DirectoryInfo(path);
        var entries = directory.EnumerateFileSystemInfos().ToList();
        var files = entries.Count(e => e is FileInfo);
        var folders = entries.Count - files;
        var rows = new List<(string, string)>
        {
            (L10n.T("preview.file_system_label_name"), directory.Name),
            (L10n.T("preview.file_system_label_type"), L10n.T("preview.file_system_type_folder")),
            (L10n.T("preview.file_system_label_items"), entries.Count.ToString()),
            (L10n.T("preview.file_system_label_files"), files.ToString()),
            (L10n.T("preview.file_system_label_folders"), folders.ToString()),
            (L10n.T("preview.file_system_label_modified"), directory.LastWriteTime.ToString("yyyy-MM-dd HH:mm")),
            (L10n.T("preview.file_system_label_path"), path),
        };
        return rows;
    }

    private FrameworkElement BuildInfoCard(List<(string Label, string Value)> rows)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = L10n.T("preview.file_system_section_info"),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("Text.Secondary"),
            Margin = new Thickness(0, 0, 0, 8),
        });
        foreach (var (label, value) in rows)
        {
            var row = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new TextBlock
            {
                Text = label,
                FontSize = 12,
                Foreground = (Brush)FindResource("Text.Secondary"),
            });
            var valueText = new TextBlock
            {
                Text = value,
                FontSize = 12,
                Foreground = (Brush)FindResource("Text.Primary"),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            if (label == L10n.T("preview.file_system_label_path"))
            {
                valueText.FontFamily = new FontFamily("Consolas, monospace");
            }
            Grid.SetColumn(valueText, 1);
            row.Children.Add(valueText);
            stack.Children.Add(row);
        }
        return WrapCard(stack);
    }

    private FrameworkElement BuildContentsCard(string directoryPath)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = L10n.T("preview.file_system_section_contents"),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("Text.Secondary"),
            Margin = new Thickness(0, 0, 0, 8),
        });
        try
        {
            var entries = new DirectoryInfo(directoryPath)
                .EnumerateFileSystemInfos()
                .OrderByDescending(e => e is DirectoryInfo)
                .ThenBy(e => e.Name, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
            if (entries.Count == 0)
            {
                stack.Children.Add(new TextBlock
                {
                    Text = L10n.T("preview.file_system_empty_directory"),
                    FontSize = 12,
                    Foreground = (Brush)FindResource("Text.Secondary"),
                });
            }
            else
            {
                foreach (var entry in entries)
                {
                    var row = new Grid { Margin = new Thickness(0, 3, 0, 3) };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    var glyph = new TextBlock
                    {
                        Text = entry is DirectoryInfo ? "\uE8B7" : "\uE8A5",
                        FontSize = 12,
                        Foreground = entry is DirectoryInfo
                            ? new SolidColorBrush(Color.FromRgb(0xE0, 0xA3, 0x29))
                            : new SolidColorBrush(Color.FromRgb(0x1F, 0x9E, 0x8C)),
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                    row.Children.Add(glyph);
                    var name = new TextBlock
                    {
                        Text = entry.Name,
                        FontSize = 12,
                        Foreground = (Brush)FindResource("Text.Primary"),
                        Margin = new Thickness(8, 0, 8, 0),
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    };
                    Grid.SetColumn(name, 1);
                    row.Children.Add(name);
                    if (entry is FileInfo fileInfo)
                    {
                        var size = new TextBlock
                        {
                            Text = FormatBytes(fileInfo.Length),
                            FontSize = 11,
                            Foreground = (Brush)FindResource("Text.Secondary"),
                        };
                        Grid.SetColumn(size, 2);
                        row.Children.Add(size);
                    }
                    stack.Children.Add(row);
                }
            }
        }
        catch (Exception)
        {
        }
        return WrapCard(stack);
    }

    private FrameworkElement WrapCard(FrameworkElement content) => new Border
    {
        Background = (Brush)FindResource("SectionCard.Background"),
        CornerRadius = new CornerRadius(14),
        Padding = new Thickness(16, 12, 16, 12),
        Margin = new Thickness(0, 0, 0, 12),
        Child = content,
    };

    private static string FormatBytes(long bytes)
    {
        if (bytes < 1024)
        {
            return $"{bytes} B";
        }
        if (bytes < 1024 * 1024)
        {
            return $"{bytes / 1024.0:0.#} KB";
        }
        if (bytes < 1024L * 1024 * 1024)
        {
            return $"{bytes / (1024.0 * 1024):0.#} MB";
        }
        return $"{bytes / (1024.0 * 1024 * 1024):0.##} GB";
    }

    // ---- dual image-file view ----------------------------------------------------------

    private void OnToggleImageMode(object sender, RoutedEventArgs e)
    {
        var showingImage = ImageModeHost.Visibility == Visibility.Visible;
        if (!showingImage)
        {
            ImageModeHost.Visibility = Visibility.Visible;
            InfoScroll.Visibility = Visibility.Collapsed;
            ToggleImageModeLabel.Text = L10n.T("preview.file_system_show_info");
            LoadImagePreview();
        }
        else
        {
            ImageModeHost.Visibility = Visibility.Collapsed;
            InfoScroll.Visibility = Visibility.Visible;
            ToggleImageModeLabel.Text = L10n.T("preview.file_system_show_image");
        }
    }

    private void LoadImagePreview()
    {
        if (_item.SingleFilePath is not { } path || !File.Exists(path))
        {
            return;
        }
        var bitmap = ClipboardWriter.DecodeBitmap(LoadBytes(path));
        if (bitmap is not null)
        {
            ImagePreview.Source = bitmap;
        }
    }

    private static byte[] LoadBytes(string path)
    {
        try
        {
            return File.ReadAllBytes(path);
        }
        catch (Exception)
        {
            return Array.Empty<byte>();
        }
    }

    // ---- actions -------------------------------------------------------------------------

    private void OnCopy(object sender, RoutedEventArgs e) => _app.Coordinator.CopyOnly(_item);

    private void OnSaveAs(object sender, RoutedEventArgs e)
    {
        var paths = (_item.Content.FilePaths ?? Array.Empty<string>()).Where(File.Exists).ToList();
        switch (paths.Count)
        {
            case 0:
                return;
            case 1:
                SaveAsService.SaveSingleFile(this, paths[0]);
                break;
            default:
                SaveAsService.SaveMultipleFiles(this, paths);
                break;
        }
    }

    private void OnCopyPath(object sender, RoutedEventArgs e) =>
        _app.Coordinator.CopyPaths(_item.Content.FilePaths ?? Array.Empty<string>());

    private void OnReveal(object sender, RoutedEventArgs e) =>
        _app.Coordinator.RevealInExplorer(_item.Content.FilePaths ?? Array.Empty<string>());

    private void OnOpen(object sender, RoutedEventArgs e) =>
        _app.Coordinator.OpenPaths(_item.Content.FilePaths ?? Array.Empty<string>());

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        _app.Store.SetFavorite(_item, !_item.IsFavorite);
        FavoriteLabel.Text = _item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
    }
}
