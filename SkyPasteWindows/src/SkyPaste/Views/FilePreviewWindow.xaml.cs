using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;
using SkyPaste.Views.Controls;

namespace SkyPaste;

/// <summary>
/// File/folder preview (mac FileSystemPreviewView): details, directory contents,
/// missing-path banner, and an image-file dual view with preview toggle.
/// </summary>
public partial class FilePreviewWindow : Window
{
    private readonly App _app;
    private readonly ClipboardItem _item;
    private readonly CancellationTokenSource _detailsCancellation = new();
    private FilePreviewSnapshot? _snapshot;
    private bool _loadingImage;
    private bool _closed;

    public FilePreviewWindow(App app, ClipboardItem item)
    {
        InitializeComponent();
        _app = app;
        _item = item;
        Title = L10n.T("preview.file_system_title");
        PreviewTitle.Text = L10n.T("preview.file_system_title");
        PreviewSource.Content = SourceIcon.CreatePreviewLabel(item);
        Width = 880;
        Height = 660;
        MinWidth = 700;
        MinHeight = 500;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        SetResourceReference(BackgroundProperty, "Window.Background");

        CopyLabel.Text = L10n.T("menu.copy");
        ShareLabel.Text = L10n.T("menu.share");
        SaveAsLabel.Text = L10n.T("menu.save_as");
        CopyPathLabel.Text = L10n.T("menu.copy_path");
        RevealLabel.Text = L10n.T("menu.reveal_in_explorer");
        OpenLabel.Text = item.OpenActionTitle;
        FavoriteLabel.Text = item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
        LoadingDetails.Text = L10n.T("preview.file_system_loading");

        if (item.IsSingleImageFile)
        {
            ToggleImageMode.Visibility = Visibility.Visible;
            ToggleImageModeLabel.Text = L10n.T("preview.file_system_show_image");
        }
        else
        {
            ToggleImageMode.Visibility = Visibility.Collapsed;
        }

        Loaded += (_, _) => WindowEffectsService.EnableRoundedCorners(this);
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };

        Loaded += async (_, _) => await LoadDetailsAsync();
        Activated += (_, _) => UpdateFavoriteLabel();
        _app.Theme.ThemeChanged += BuildDetails;
        Closed += (_, _) =>
        {
            _closed = true;
            _detailsCancellation.Cancel();
            _detailsCancellation.Dispose();
            _app.Theme.ThemeChanged -= BuildDetails;
        };
    }

    private async Task LoadDetailsAsync()
    {
        var paths = _item.FilePaths ?? Array.Empty<string>();
        var token = _detailsCancellation.Token;
        try
        {
            var snapshot = await Task.Run(() => FilePreviewSnapshot.Build(paths, token), token);
            await Dispatcher.InvokeAsync(() =>
            {
                if (!token.IsCancellationRequested)
                {
                    _snapshot = snapshot;
                    BuildDetails();
                }
            });
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
    }

    private void BuildDetails()
    {
        if (_snapshot is not { } snapshot)
        {
            return;
        }

        InfoHost.Children.Clear();
        var missing = snapshot.Selection.Where(entry => !entry.Exists).Select(entry => entry.Path).ToArray();
        if (missing.Length != 0)
        {
            InfoHost.Children.Add(WrapCard(new TextBlock
            {
                Text = L10n.T("preview.file_system_not_found") + "\n" + string.Join("\n", missing),
                FontSize = 12,
                Foreground = (Brush)FindResource("Text.Primary"),
                TextWrapping = TextWrapping.Wrap,
            }, new SolidColorBrush(Color.FromArgb(40, 0xE0, 0xA3, 0x29))));
        }

        var single = snapshot.Selection.Count == 1 ? snapshot.Selection[0] : null;
        var files = snapshot.Selection.Count(entry => !entry.IsFolder);
        var size = snapshot.Selection.Where(entry => entry.Size.HasValue).Select(entry => entry.Size!.Value).ToArray();
        var type = files == 0 ? "folder" : files == snapshot.Selection.Count ? "file" : "mixed";
        var rows = new List<(string Label, string Value)>
        {
            (L10n.T("preview.file_system_label_name"), single?.Name ?? _item.Title),
            (L10n.T("preview.file_system_label_type"), L10n.T($"preview.file_system_type_{type}")),
        };
        if (single is { IsFolder: false } && Path.GetExtension(single.Name) is { Length: > 1 } extension)
        {
            rows.Add((L10n.T("preview.file_system_label_extension"), extension[1..].ToUpperInvariant()));
        }

        rows.Add((L10n.T("preview.file_system_label_size"), size.Length > 0
            ? FilePreviewSnapshot.FormatSize(size.Sum()) : L10n.T("preview.file_system_unavailable")));
        if (single?.Modified is DateTime modified)
        {
            rows.Add((L10n.T("preview.file_system_label_modified"), modified.ToString("g")));
        }
        rows.Add((L10n.T("preview.file_system_label_path"), single?.Path ?? L10n.T("preview.file_system_multiple_locations")));
        if (snapshot.Selection.Count > 1)
        {
            rows.Add((L10n.T("preview.file_system_label_items"), L10n.Format("preview.file_system_item_count", snapshot.Selection.Count)));
        }
        else if (single is { Exists: true, IsFolder: true })
        {
            var folders = snapshot.Contents.Count(entry => entry.IsFolder);
            rows.Add((L10n.T("preview.file_system_label_items"), L10n.Format("preview.file_system_item_count", snapshot.Contents.Count)));
            rows.Add((L10n.T("preview.file_system_label_files"), L10n.Format("preview.file_system_file_count", snapshot.Contents.Count - folders)));
            rows.Add((L10n.T("preview.file_system_label_folders"), L10n.Format("preview.file_system_folder_count", folders)));
        }
        InfoHost.Children.Add(BuildInfoCard(rows));
        if (single is { IsFolder: true } || snapshot.Selection.Count > 1)
        {
            InfoHost.Children.Add(BuildContentsCard(snapshot.Contents));
        }
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
            var valueText = new TextBox
            {
                Text = value,
                FontSize = 12,
                Foreground = (Brush)FindResource("Text.Primary"),
                IsReadOnly = true,
                TextWrapping = TextWrapping.Wrap,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
            };
            if (label == L10n.T("preview.file_system_label_path"))
            {
                valueText.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            }
            Grid.SetColumn(valueText, 1);
            row.Children.Add(valueText);
            stack.Children.Add(row);
        }
        return WrapCard(stack);
    }

    private FrameworkElement BuildContentsCard(IReadOnlyList<FilePreviewEntry> entries)
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
            var list = new ListBox
            {
                ItemsSource = entries,
                ItemTemplate = (DataTemplate)FindResource("FileEntryTemplate"),
                MaxHeight = 340,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
            };
            ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
            ScrollViewer.SetCanContentScroll(list, true);
            VirtualizingPanel.SetVirtualizationMode(list, VirtualizationMode.Recycling);
            stack.Children.Add(list);
        }
        return WrapCard(stack);
    }

    private FrameworkElement WrapCard(FrameworkElement content, Brush? background = null) => new Border
    {
        Background = background ?? (Brush)FindResource("SectionCard.Background"),
        CornerRadius = new CornerRadius(14),
        Padding = new Thickness(16, 12, 16, 12),
        Margin = new Thickness(0, 0, 0, 12),
        Child = content,
    };

    // ---- dual image-file view ----------------------------------------------------------

    private async void OnToggleImageMode(object sender, RoutedEventArgs e)
    {
        var showingImage = ImageModeHost.Visibility == Visibility.Visible;
        if (!showingImage)
        {
            ImageModeHost.Visibility = Visibility.Visible;
            InfoScroll.Visibility = Visibility.Collapsed;
            ToggleImageModeLabel.Text = L10n.T("preview.file_system_show_info");
            await LoadImagePreviewAsync();
        }
        else
        {
            ImageModeHost.Visibility = Visibility.Collapsed;
            InfoScroll.Visibility = Visibility.Visible;
            FavoriteLabel.Text = _item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
            ToggleImageModeLabel.Text = L10n.T("preview.file_system_show_image");
        }
    }

    private async Task LoadImagePreviewAsync()
    {
        if (_loadingImage || ImageModeHost.Content is ImagePreviewWorkspace || _item.SingleFilePath is not { } path)
        {
            return;
        }
        _loadingImage = true;
        ImageModeHost.Content = new ProgressBar
        {
            IsIndeterminate = true, Width = 160,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        var (bytes, bitmap) = await Task.Run(() => ReadImageFile(path));
        await Dispatcher.InvokeAsync(() =>
        {
            _loadingImage = false;
            if (_closed)
            {
                return;
            }
            if (bytes is null || bitmap is null)
            {
                ShowImageUnavailable();
                return;
            }
            var image = new ClipboardItem(
                Guid.NewGuid(), _item.CreatedAt,
                ClipboardContent.FromImage(bytes, Path.GetFileNameWithoutExtension(path), bytes.LongLength, previewOnly: false),
                _item.Fingerprint, _item.Source, _item.SourceApp);
            ImageModeHost.Content = new ImagePreviewWorkspace(_app, image, _item, bitmap);
        });
    }

    private static (byte[]? Bytes, System.Windows.Media.Imaging.BitmapSource? Bitmap) ReadImageFile(string path)
    {
        try
        {
            var bytes = File.ReadAllBytes(path);
            return (bytes, ClipboardWriter.DecodeBitmap(bytes));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            App.UiLog($"Image-file preview failed: {error.GetType().Name}");
            return (null, null);
        }
    }

    private void ShowImageUnavailable()
    {
        ImageModeHost.Content = new TextBlock
        {
            Text = L10n.T("preview.unavailable"),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Brush)FindResource("Text.Secondary"),
        };
    }

    // ---- actions -------------------------------------------------------------------------

    private void OnCopy(object sender, RoutedEventArgs e) => _app.Coordinator.CopyOnly(_item);

    private void OnShare(object sender, RoutedEventArgs e) => _app.Coordinator.Share(this, _item);

    private void OnSaveAs(object sender, RoutedEventArgs e)
    {
        var paths = _item.Content.FilePaths ?? Array.Empty<string>();
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
        _app.Store.SetFavorite(_item, !_app.Store.IsFavorite(_item));
        UpdateFavoriteLabel();
    }

    private void UpdateFavoriteLabel() =>
        FavoriteLabel.Text = _app.Store.IsFavorite(_item) ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
}
