using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SkyPaste.Core.Core;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;

namespace SkyPaste.Views.Controls;

/// <summary>
/// Shared clipboard list UI for the main panel and the tray popover
/// (mirrors SkyPanelView + SkyMenuBarClipboardView): header, deferred search,
/// filter chips with source menu, day-grouped cards, footer actions, batch mode.
/// </summary>
public partial class ClipboardListPanel : UserControl
{
    private readonly App _app;
    private readonly bool _popoverMode;

    private ClipboardFilter _selectedFilter = ClipboardFilter.All;
    private ClipboardSourceSelection _sourceSelection = ClipboardSourceSelection.AllApps;
    private Guid? _selectedItemId;
    private bool _batchMode;
    private readonly HashSet<Guid> _batchSelection = new();
    private string _searchText = string.Empty;
    private DispatcherTimer? _searchDebounce;
    private DispatcherTimer? _pendingPrimaryAction;
    private bool _rebuilding;
    private bool _suppressSearchCallback;

    private List<RowModel> _flatRows = new();
    private readonly Dictionary<Guid, Border> _rowBorders = new();

    public event Action? CloseRequested;

    public ClipboardListPanel(App app, bool popoverMode)
    {
        InitializeComponent();
        _app = app;
        _popoverMode = popoverMode;

        if (popoverMode)
        {
            BatchToggle.Visibility = Visibility.Collapsed;
            CloseToggle.Visibility = Visibility.Collapsed;
            StatsToggle.Visibility = Visibility.Visible;
        }
        else
        {
            StatsToggle.Visibility = Visibility.Collapsed;
        }

        _app.Settings.FilterOrderSettingsChanged += RebuildChips;
        L10n.LanguageChanged += RefreshLocalization;
        Loaded += (_, _) => { RefreshLocalization(); RebuildChips(); Rebuild(); };
        Unloaded += (_, _) => _pendingPrimaryAction?.Stop();
    }

    // ---- public API -------------------------------------------------------------

    public void OnStoreChanged() => Dispatcher.BeginInvoke(Rebuild);

    public void RefreshLocalization()
    {
        HeaderTitle.Text = "SkyPaste";
        HeaderHint.Text = _popoverMode
            ? L10n.T("menu.clipboard_manager")
            : (_app.Settings.AutoPasteEnabled
                ? L10n.T("panel.shortcut_hint")
                : L10n.T("panel.shortcut_hint_copy_only"));
        RebuildChips();
        Rebuild();
    }

    /// <summary>Central keyboard handler; returns true when the key was consumed.</summary>
    public bool HandleKeyDown(Key key, ModifierKeys modifiers)
    {
        switch (key)
        {
            case Key.Escape when !_popoverMode:
                CancelPendingPrimaryAction();
                CloseRequested?.Invoke();
                return true;
            case Key.Enter:
                CancelPendingPrimaryAction();
                var selected = SelectedRow;
                if (selected is not null)
                {
                    RunPrimaryAction(selected.Item);
                }
                return true;
            case Key.C when modifiers.HasFlag(ModifierKeys.Control):
                CancelPendingPrimaryAction();
                if (SelectedRow is { } copyRow)
                {
                    _app.Coordinator.CopyOnly(copyRow.Item);
                }
                return true;
            case Key.Up when modifiers == ModifierKeys.None:
                MoveSelection(-1);
                return true;
            case Key.Down when modifiers == ModifierKeys.None:
                MoveSelection(1);
                return true;
        }

        if (modifiers.HasFlag(ModifierKeys.Control) && key is >= Key.D1 and <= Key.D9)
        {
            var index = key - Key.D1;
            if (index < _flatRows.Count)
            {
                CancelPendingPrimaryAction();
                var row = _flatRows[index];
                _selectedItemId = row.Item.Id;
                Rebuild();
                _app.Coordinator.CopyOnly(row.Item);
                return true;
            }
        }
        return false;
    }

    public void FocusSearch() => ToggleSearch(open: true);

    // ---- models -------------------------------------------------------------------

    public sealed class RowModel
    {
        public required ClipboardItem Item { get; init; }
        public required string Title { get; init; }
        public required string Subtitle { get; init; }
        public required string Time { get; init; }
        public required string IconGlyph { get; init; }
        public required Brush IconBrush { get; init; }
        public required string? IconBackground { get; init; }
        public Border? Border { get; set; }
        public bool IsFavorite => Item.IsFavorite;
        public bool ShowThumbnail => Item.IsImage || Item.IsSingleImageFile;
        public byte[]? ThumbBytes;
        public string? SourceBadge => Item.SourceApp?.Name;
        public string? DeviceBadge => Item.DeviceName;
        public bool IsDevice => Item.Source.IsDeviceSynced();
    }

    private RowModel? SelectedRow =>
        _selectedItemId is { } id ? _flatRows.FirstOrDefault(r => r.Item.Id == id) : null;

    private IReadOnlyList<ClipboardItem> CurrentItems =>
        _app.Store.FilteredItemsByFilter.TryGetValue(_selectedFilter, out var items)
            ? items
            : Array.Empty<ClipboardItem>();

    // ---- rebuild --------------------------------------------------------------------

    private void Rebuild()
    {
        if (_rebuilding || !IsLoaded)
        {
            return;
        }
        _rebuilding = true;
        try
        {
            var items = CurrentItems;
            if (_popoverMode && _selectedFilter != ClipboardFilter.Favorites)
            {
                items = items.Take(80).ToList();
            }

            SectionHost.Children.Clear();
            _rowBorders.Clear();
            _flatRows = new List<RowModel>();
            int rowIndex = 0;

            if (_selectedFilter == ClipboardFilter.Favorites)
            {
                if (items.Count == 0)
                {
                    AddEmptyState();
                }
                else
                {
                    AddSectionCard(L10n.T("section.favorites"), items, ref rowIndex, allowDayDelete: false);
                }
            }
            else
            {
                var groups = items
                    .GroupBy(i => i.CreatedAt.ToLocalTime().Date)
                    .OrderByDescending(g => g.Key)
                    .ToList();
                if (groups.Count == 0)
                {
                    AddEmptyState();
                }
                else
                {
                    foreach (var group in groups)
                    {
                        AddSectionCard(L10n.SectionTitle(group.Key), group.ToList(), ref rowIndex, allowDayDelete: true);
                    }
                }
            }

            UpdateFooter();
            UpdateSearchVisibility();
        }
        finally
        {
            _rebuilding = false;
        }
    }

    private void AddSectionCard(string title, IReadOnlyList<ClipboardItem> items, ref int rowIndex, bool allowDayDelete)
    {
        var card = new Border
        {
            CornerRadius = new CornerRadius(16),
            Background = (Brush)FindResource("SectionCard.Background"),
            Padding = new Thickness(6),
            Margin = new Thickness(0, 0, 0, 12),
        };
        var stack = new StackPanel();

        var header = new Grid { Margin = new Thickness(8, 4, 8, 6) };
        header.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("Text.Secondary"),
        });
        if (allowDayDelete)
        {
            var deleteDay = new Button
            {
                Style = (Style)FindResource("IconIconButton"),
                HorizontalAlignment = HorizontalAlignment.Right,
                Content = new TextBlock { Text = "\uE74D", FontSize = 11 },
                ToolTip = L10n.T("menu.delete"),
            };
            deleteDay.Click += (_, _) => ShowDeleteDayConfirm(items);
            header.Children.Add(deleteDay);
        }
        stack.Children.Add(header);

        for (var i = 0; i < items.Count; i++)
        {
            var row = BuildRow(items[i], rowIndex);
            _flatRows.Add(row);
            stack.Children.Add(row.Border);
            rowIndex++;
        }

        card.Child = stack;
        SectionHost.Children.Add(card);
    }

    private RowModel BuildRow(ClipboardItem item, int index)
    {
        var row = new RowModel
        {
            Item = item,
            Title = item.Title,
            Subtitle = item.Subtitle,
            Time = L10n.TimeText(item.CreatedAt),
            IconGlyph = IconGlyphFor(item),
            IconBrush = IconBrushFor(item),
            IconBackground = null,
        };

        var border = new Border
        {
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(9, 8, 9, 8),
            Tag = (row, index),
            Cursor = Cursors.Hand,
            ContextMenu = BuildRowContextMenu(item),
        };
        _rowBorders[item.Id] = border;

        var grid = new Grid { MinHeight = 44 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (row.ShowThumbnail)
        {
            var thumbBorder = new Border
            {
                Width = 44,
                Height = 44,
                CornerRadius = new CornerRadius(8),
                Background = (Brush)FindResource("IconBlock.Background"),
                ClipToBounds = true,
                Margin = new Thickness(0, 0, 10, 0),
            };
            var placeholder = new TextBlock
            {
                Text = "\uE8B9",
                FontSize = 14,
                Foreground = (Brush)FindResource("Text.Secondary"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
            thumbBorder.Child = placeholder;
            grid.Children.Add(thumbBorder);
            LoadThumbnail(row, thumbBorder, placeholder);
        }
        else
        {
            var iconBorder = new Border
            {
                Width = 16,
                Height = 16,
                CornerRadius = new CornerRadius(4),
                Background = (Brush)FindResource("IconBlock.Background"),
                Margin = new Thickness(0, 0, 10, 0),
                Child = new TextBlock
                {
                    Text = row.IconGlyph,
                    FontSize = 9,
                    Foreground = row.IconBrush,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            };
            grid.Children.Add(iconBorder);
        }

        var textStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var titleBlock = new TextBlock
        {
            Text = row.Title,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("Text.Primary"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxHeight = 32,
        };
        if (item.IsCode)
        {
            titleBlock.FontFamily = new FontFamily("Consolas, Menlo, monospace");
            titleBlock.TextTrimming = TextTrimming.CharacterEllipsis;
        }
        textStack.Children.Add(titleBlock);

        var metaStack = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 3, 0, 0) };
        metaStack.Children.Add(new TextBlock
        {
            Text = row.Subtitle + "  ·  " + row.Time,
            FontSize = 10,
            Foreground = (Brush)FindResource("Text.Secondary"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var badgeName = row.SourceBadge ?? row.DeviceBadge;
        if (badgeName is not null)
        {
            metaStack.Children.Add(new TextBlock
            {
                Text = "  ·  " + (row.IsDevice ? "\uD83D\uDCF1 " : string.Empty) + badgeName,
                FontSize = 10,
                Foreground = (Brush)FindResource("Text.Secondary"),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = 140,
            });
        }
        textStack.Children.Add(metaStack);
        Grid.SetColumn(textStack, 1);
        grid.Children.Add(textStack);

        var tailStack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
        };
        if (_batchMode)
        {
            tailStack.Children.Add(new TextBlock
            {
                Name = "BatchGlyph",
                Text = _batchSelection.Contains(item.Id) ? "\uE73E" : "\uE739",
                FontSize = 13,
                Foreground = _batchSelection.Contains(item.Id)
                    ? (Brush)FindResource("AccentBrush")
                    : (Brush)FindResource("Text.Secondary"),
            });
        }
        else if (item.IsFavorite)
        {
            tailStack.Children.Add(new TextBlock
            {
                Text = "\uE735",
                FontSize = 11,
                Foreground = (Brush)FindResource("Favorite"),
            });
        }
        Grid.SetColumn(tailStack, 2);
        grid.Children.Add(tailStack);

        border.Child = grid;

        border.MouseDown += (_, e) =>
        {
            if (e.ChangedButton == MouseButton.Left)
            {
                SelectRow(item.Id);
            }
        };
        border.MouseUp += (_, e) =>
        {
            if (e.ChangedButton == MouseButton.Left && !_batchMode)
            {
                SchedulePendingPrimaryAction(item);
            }
        };
        border.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2 && !_batchMode)
            {
                CancelPendingPrimaryAction();
                _app.Coordinator.OpenPreview(item);
            }
        };
        border.MouseLeave += (_, _) => { /* drag handled via system DragDrop below */ };
        border.PreviewMouseMove += (_, e) =>
        {
            if (e.LeftButton == MouseButtonState.Pressed && !_batchMode && DragOutService.CanDrag(item))
            {
                var data = DragOutService.BuildDataObject(item);
                if (data is not null)
                {
                    CancelPendingPrimaryAction();
                    DragOutService.StartDrag(border, data);
                }
            }
        };

        row.Border = border;
        UpdateRowVisual(item.Id);
        return row;
    }

    private void LoadThumbnail(RowModel row, Border thumbBorder, FrameworkElement placeholder)
    {
        Task.Run(() =>
        {
            try
            {
                if (row.Item.IsImage)
                {
                    return ThumbnailProvider.Shared.GetImageThumbnail(row.Item);
                }
                return row.Item.SingleFilePath is { } path
                    ? ThumbnailProvider.Shared.GetFileThumbnail(path)
                    : null;
            }
            catch (Exception)
            {
                return null;
            }
        }).ContinueWith(task =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (_flatRows.All(r => r.Item.Id != row.Item.Id))
                {
                    return;
                }
                if (task.Result is not { Length: > 0 } bytes)
                {
                    return;
                }
                var image = new BitmapImage();
                using var stream = new MemoryStream(bytes);
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.StreamSource = stream;
                image.EndInit();
                image.Freeze();
                thumbBorder.Child = new Image
                {
                    Source = image,
                    Stretch = Stretch.UniformToFill,
                    MaxWidth = 44,
                    MaxHeight = 44,
                };
            });
        });
        _ = placeholder;
    }

    private async void SchedulePendingPrimaryAction(ClipboardItem item)
    {
        if (_popoverMode)
        {
            // Tray popover: single click copies (no paste-back) after the
            // double-click window, mirroring the macOS popover behavior.
            var copyTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
            copyTimer.Tick += (_, _) =>
            {
                copyTimer.Stop();
                if (_selectedItemId == item.Id)
                {
                    _app.Coordinator.CopyOnly(item);
                }
            };
            copyTimer.Start();
            await Task.CompletedTask;
            return;
        }
        if (!_app.Settings.AutoPasteEnabled)
        {
            return;
        }
        CancelPendingPrimaryAction();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (_selectedItemId == item.Id)
            {
                _app.Coordinator.Paste(item);
            }
        };
        _pendingPrimaryAction = timer;
        timer.Start();
        await Task.CompletedTask;
    }

    private void CancelPendingPrimaryAction()
    {
        _pendingPrimaryAction?.Stop();
        _pendingPrimaryAction = null;
    }

    private void RunPrimaryAction(ClipboardItem item)
    {
        if (_app.Settings.AutoPasteEnabled && !_popoverMode)
        {
            _app.Coordinator.Paste(item);
        }
        else
        {
            _app.Coordinator.CopyOnly(item);
        }
    }

    private void SelectRow(Guid? id)
    {
        if (_batchMode && id is { } batchId)
        {
            if (!_batchSelection.Add(batchId))
            {
                _batchSelection.Remove(batchId);
            }
            Rebuild();
            return;
        }
        _selectedItemId = id;
        foreach (var (itemId, border) in _rowBorders)
        {
            UpdateRowVisual(itemId);
        }
    }

    private void UpdateRowVisual(Guid itemId)
    {
        if (!_rowBorders.TryGetValue(itemId, out var border))
        {
            return;
        }
        var isSelected = _selectedItemId == itemId;
        var inBatch = _batchSelection.Contains(itemId);
        border.Background = _batchMode && inBatch
            ? (Brush)FindResource("Row.Selected.Background")
            : isSelected
                ? (Brush)FindResource("Row.Selected.Background")
                : Brushes.Transparent;
        border.BorderBrush = isSelected
            ? (Brush)FindResource("Row.Selected.Border")
            : Brushes.Transparent;
        border.BorderThickness = new Thickness(1);
    }

    private void MoveSelection(int delta)
    {
        if (_flatRows.Count == 0)
        {
            return;
        }
        var currentIndex = _selectedItemId is { } id
            ? _flatRows.FindIndex(r => r.Item.Id == id)
            : -1;
        var nextIndex = Math.Clamp((currentIndex < 0 ? (delta > 0 ? -1 : 1) : currentIndex) + delta, 0, _flatRows.Count - 1);
        if (nextIndex < 0)
        {
            nextIndex = 0;
        }
        _selectedItemId = _flatRows[nextIndex].Item.Id;
        foreach (var itemId in _rowBorders.Keys)
        {
            UpdateRowVisual(itemId);
        }
        var border = _rowBorders[_selectedItemId.Value];
        border.BringIntoView();
    }

    // ---- sections helpers -------------------------------------------------------------

    private void AddEmptyState()
    {
        var searching = _searchText.Length > 0;
        var card = new Border
        {
            CornerRadius = new CornerRadius(16),
            Background = (Brush)FindResource("SectionCard.Background"),
            Padding = new Thickness(24),
            MinHeight = 220,
            Margin = new Thickness(0, 0, 0, 12),
            Child = new StackPanel
            {
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children =
                {
                    new TextBlock
                    {
                        Text = searching ? "\uE71E" : "\uE7B8",
                        FontSize = 28,
                        Foreground = (Brush)FindResource("Text.Secondary"),
                        HorizontalAlignment = HorizontalAlignment.Center,
                    },
                    new TextBlock
                    {
                        Text = searching ? L10n.T("panel.search_empty_title") : L10n.T("panel.empty_title"),
                        FontSize = 14,
                        FontWeight = FontWeights.SemiBold,
                        Foreground = (Brush)FindResource("Text.Primary"),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Margin = new Thickness(0, 10, 0, 0),
                    },
                    new TextBlock
                    {
                        Text = searching
                            ? (_selectedFilter == ClipboardFilter.All
                                ? L10n.T("panel.search_empty_message")
                                : L10n.Format("panel.search_empty_message_scoped", FilterLabel(_selectedFilter)))
                            : (_selectedFilter == ClipboardFilter.All
                                ? L10n.T("panel.empty_message")
                                : L10n.Format("panel.empty_message_scoped", FilterLabel(_selectedFilter))),
                        FontSize = 11,
                        Foreground = (Brush)FindResource("Text.Secondary"),
                        TextWrapping = TextWrapping.Wrap,
                        TextAlignment = TextAlignment.Center,
                        MaxWidth = 360,
                        HorizontalAlignment = HorizontalAlignment.Center,
                        Margin = new Thickness(0, 6, 0, 0),
                    },
                },
            },
        };
        if (searching)
        {
            var clearButton = new Button
            {
                Style = (Style)FindResource("CapsuleButton"),
                Content = L10n.T("panel.clear_search"),
                Margin = new Thickness(0, 12, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Center,
            };
            clearButton.Click += (_, _) => ToggleSearch(open: false);
            ((StackPanel)card.Child).Children.Add(clearButton);
        }
        SectionHost.Children.Add(card);
    }

    private static string FilterLabel(ClipboardFilter filter) => L10n.T(filter.LocalizationKey());

    // ---- delete day confirm overlay ---------------------------------------------------

    private void ShowDeleteDayConfirm(IReadOnlyList<ClipboardItem> items)
    {
        var day = items.Count > 0 ? items[0].CreatedAt.ToLocalTime().Date : DateTime.Today;
        var overlay = BuildConfirmDialog(
            title: L10n.T("menu.delete_day_title"),
            message: L10n.Format("menu.delete_day_message", L10n.SectionTitle(day)),
            confirmText: L10n.T("menu.delete"),
            onConfirm: () =>
            {
                _app.Store.DeleteAllItemsOnDay(day);
                _app.Toast.Show(L10n.Format("panel.batch_delete_success", items.Count));
            });
        ShowOverlay(overlay);
    }

    private FrameworkElement BuildConfirmDialog(string title, string message, string confirmText, Action onConfirm)
    {
        var root = new Grid();
        var scrim = new Border { Background = (Brush)FindResource("Overlay.Scrim") };
        scrim.MouseLeftButtonDown += (_, _) => HideOverlay();

        var dialog = new Border
        {
            Width = 340,
            CornerRadius = new CornerRadius(18),
            Background = (Brush)FindResource("Dialog.Background"),
            Padding = new Thickness(22),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Effect = (System.Windows.Media.Effects.Effect)FindResource("Card.Shadow"),
            Child = new StackPanel
            {
                Children =
                {
                    new TextBlock
                    {
                        Text = title,
                        FontSize = 15,
                        FontWeight = FontWeights.SemiBold,
                        Foreground = (Brush)FindResource("Text.Primary"),
                    },
                    new TextBlock
                    {
                        Text = message,
                        FontSize = 12,
                        TextWrapping = TextWrapping.Wrap,
                        Foreground = (Brush)FindResource("Text.Secondary"),
                        Margin = new Thickness(0, 8, 0, 0),
                    },
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal,
                        HorizontalAlignment = HorizontalAlignment.Right,
                        Margin = new Thickness(0, 16, 0, 0),
                        Children =
                        {
                            NewFooterButton(L10n.T("menu.cancel"), () => HideOverlay()),
                            NewFooterButton(confirmText, () =>
                            {
                                HideOverlay();
                                onConfirm();
                            }, danger: true),
                        },
                    },
                },
            },
        };
        root.Children.Add(scrim);
        root.Children.Add(dialog);
        return root;
    }

    private void ShowOverlay(FrameworkElement overlay)
    {
        OverlayHost.Content = overlay;
        OverlayHost.Visibility = Visibility.Visible;
    }

    private void HideOverlay()
    {
        OverlayHost.Content = null;
        OverlayHost.Visibility = Visibility.Collapsed;
    }

    // ---- filter chips -------------------------------------------------------------------

    private void RebuildChips()
    {
        if (FilterChips is null)
        {
            return;
        }
        FilterChips.Children.Clear();
        var order = ClipboardFilterExtensions.FullDisplayOrder(_app.Settings.FilterOrder
            .Select(s => Enum.TryParse<ClipboardFilter>(s, out var f) ? f : ClipboardFilter.Text));
        foreach (var filter in order)
        {
            FilterChips.Children.Add(BuildChip(filter));
        }
    }

    private Border BuildChip(ClipboardFilter filter)
    {
        var isSelected = _selectedFilter == filter;
        var chip = new Border
        {
            CornerRadius = new CornerRadius(13),
            Padding = new Thickness(11, 5, 11, 5),
            Margin = new Thickness(0, 0, 6, 0),
            Cursor = Cursors.Hand,
            Tag = filter,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Children =
                {
                    new TextBlock
                    {
                        Text = filter.IconGlyph(),
                        FontSize = 10,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                    new TextBlock
                    {
                        Text = L10n.T(filter.LocalizationKey()),
                        FontSize = 11,
                        Margin = new Thickness(5, 0, 0, 0),
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                },
            },
        };
        if (filter == ClipboardFilter.Favorites)
        {
            chip.Padding = new Thickness(9, 5, 9, 5);
        }
        UpdateChipVisual(chip, filter, isSelected);

        chip.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 1)
            {
                SelectFilter(filter);
            }
        };

        var menu = new ContextMenu();
        var moveFirst = new MenuItem { Header = L10n.T("filter.move_first") };
        moveFirst.Click += (_, _) => MoveChip(filter, toFront: true);
        var moveLast = new MenuItem { Header = L10n.T("filter.move_last") };
        moveLast.Click += (_, _) => MoveChip(filter, toFront: false);
        var reset = new MenuItem { Header = L10n.T("filter.reset_order") };
        reset.Click += (_, _) =>
        {
            _app.Settings.FilterOrder = new List<string>();
            RebuildChips();
        };
        menu.Items.Add(moveFirst);
        menu.Items.Add(moveLast);
        menu.Items.Add(reset);
        chip.ContextMenu = menu;

        chip.AllowDrop = true;
        chip.MouseMove += (_, e) =>
        {
            if (e.LeftButton == MouseButtonState.Pressed
                && ClipboardFilterExtensions.ReorderableCases.Contains(filter))
            {
                DragDrop.DoDragDrop(chip, filter.ToString(), DragDropEffects.Move);
            }
        };
        chip.DragOver += (_, e) =>
        {
            if (e.Data.GetDataPresent(DataFormats.StringFormat))
            {
                e.Effects = DragDropEffects.Move;
            }
            else
            {
                e.Effects = DragDropEffects.None;
            }
            e.Handled = true;
        };
        chip.Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.StringFormat) is string raw
                && Enum.TryParse<ClipboardFilter>(raw, out var dragged)
                && dragged != filter
                && ClipboardFilterExtensions.ReorderableCases.Contains(dragged))
            {
                var orderList = _app.Settings.FilterOrder.Select(s =>
                    Enum.TryParse<ClipboardFilter>(s, out var f) ? f : ClipboardFilter.Text).ToList();
                var targetList = new List<ClipboardFilter>(ClipboardFilterExtensions.ReorderableCases);
                targetList.Remove(dragged);
                var insertIndex = filter == ClipboardFilter.All || filter == ClipboardFilter.Favorites
                    ? targetList.Count
                    : targetList.IndexOf(filter);
                targetList.Insert(Math.Max(0, insertIndex), dragged);
                _app.Settings.FilterOrder = targetList.Select(f => f.ToString()).ToList();
                RebuildChips();
                e.Handled = true;
            }
        };
        return chip;
    }

    private void UpdateChipVisual(Border chip, ClipboardFilter filter, bool isSelected)
    {
        chip.Background = isSelected
            ? (Brush)FindResource("Chip.Selected.Background")
            : (Brush)FindResource("Chip.Unselected.Background");
        chip.BorderBrush = isSelected
            ? (Brush)FindResource("AccentBorderBrush")
            : (Brush)FindResource("Chip.Unselected.Border");
        chip.BorderThickness = new Thickness(1);
        if (chip.Child is StackPanel stack)
        {
            foreach (var child in stack.Children.OfType<TextBlock>())
            {
                child.Foreground = isSelected
                    ? (Brush)FindResource("Chip.Selected.Foreground")
                    : (Brush)FindResource("Text.Primary");
            }
        }
    }

    private void MoveChip(ClipboardFilter filter, bool toFront)
    {
        var current = _app.Settings.FilterOrder
            .Select(s => Enum.TryParse<ClipboardFilter>(s, out var f) ? f : ClipboardFilter.Text)
            .ToList();
        current.Remove(filter);
        if (toFront)
        {
            current.Insert(0, filter);
        }
        else
        {
            current.Add(filter);
        }
        _app.Settings.FilterOrder = current.Select(f => f.ToString()).ToList();
        RebuildChips();
    }

    private void SelectFilter(ClipboardFilter filter)
    {
        _selectedFilter = filter;
        _selectedItemId = null;
        _batchSelection.Clear();
        RebuildChips();
        Rebuild();
        UpdateSourceMenuLabel();
    }

    private void UpdateSourceMenuLabel()
    {
        SourceMenuLabel.Text = _sourceSelection.Kind switch
        {
            ClipboardSourceSelection.SelectionKind.Device => L10n.T("filter.source_device"),
            ClipboardSourceSelection.SelectionKind.App => _sourceSelection.ProcessId is { } pid
                ? (_app.Store.SourceAppOptionsByFilter.TryGetValue(_selectedFilter, out var options)
                    ? options.FirstOrDefault(o => o.ProcessId == pid)?.Name ?? L10n.T("filter.source_label")
                    : L10n.T("filter.source_label"))
                : L10n.T("filter.source_label"),
            _ => L10n.T("filter.source_all"),
        };
        SourceMenuGlyph.Text = _sourceSelection.Kind switch
        {
            ClipboardSourceSelection.SelectionKind.Device => "\uD83D\uDCF1",
            ClipboardSourceSelection.SelectionKind.App => "\uE77B",
            _ => "\uE8A9",
        };
    }

    // ---- source menu ---------------------------------------------------------------------

    private void OnSourceMenuClick(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = SourceMenuButton, Placement = PlacementMode.Bottom };

        var allApps = NewSourceMenuItem(L10n.T("filter.source_all"), "\uE8A9",
            ClipboardSourceSelection.AllApps);
        var devices = NewSourceMenuItem(L10n.T("filter.source_device"), "\uD83D\uDCF1",
            ClipboardSourceSelection.Device);
        devices.IsEnabled = _app.Store.Items.Any(i => i.Source.IsDeviceSynced());
        menu.Items.Add(allApps);
        menu.Items.Add(new Separator());
        menu.Items.Add(devices);
        menu.Items.Add(new Separator());

        if (_app.Store.SourceAppOptionsByFilter.TryGetValue(_selectedFilter, out var options))
        {
            foreach (var option in options)
            {
                menu.Items.Add(NewSourceMenuItem(option.Name, "\uE77B",
                    ClipboardSourceSelection.ForApp(option.ProcessId)));
            }
        }
        menu.IsOpen = true;
    }

    private MenuItem NewSourceMenuItem(string header, string glyph, ClipboardSourceSelection selection)
    {
        var item = new MenuItem
        {
            Header = header,
            Icon = new TextBlock { Text = glyph, FontSize = 11 },
            IsChecked = _sourceSelection.Equals(selection),
        };
        item.Click += (_, _) =>
        {
            _sourceSelection = selection;
            UpdateSourceMenuLabel();
            Rebuild();
        };
        return item;
    }

    // ---- search ------------------------------------------------------------------------------

    private void OnSearchToggleClick(object sender, RoutedEventArgs e) =>
        ToggleSearch(SearchBar.Visibility != Visibility.Visible);

    private void ToggleSearch(bool open)
    {
        SearchBar.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        if (open)
        {
            SearchBox.Focus();
        }
        else
        {
            _suppressSearchCallback = true;
            SearchBox.Text = string.Empty;
            _suppressSearchCallback = false;
            _searchText = string.Empty;
            _app.Store.SetSearchQuery(string.Empty);
            Dispatcher.BeginInvoke(Rebuild);
        }
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressSearchCallback)
        {
            return;
        }
        SearchClear.Visibility = SearchBox.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _searchDebounce?.Stop();
        _searchDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        _searchDebounce.Tick += (_, _) =>
        {
            _searchDebounce?.Stop();
            _searchText = SearchBox.Text.Trim();
            _app.Store.SetSearchQuery(_searchText);
            Dispatcher.BeginInvoke(Rebuild);
        };
        _searchDebounce.Start();
    }

    private void OnSearchBoxKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            ToggleSearch(false);
            e.Handled = true;
        }
        else if (e.Key == Key.Enter)
        {
            SearchBox.MoveFocus(new TraversalRequest(FocusNavigationDirection.Down));
            e.Handled = true;
        }
    }

    private void OnSearchClearClick(object sender, RoutedEventArgs e) => ToggleSearch(false);

    private void OnFilterScroll(object sender, MouseWheelEventArgs e)
    {
        var scrollViewer = (ScrollViewer)sender;
        scrollViewer.ScrollToHorizontalOffset(scrollViewer.HorizontalOffset - e.Delta);
        e.Handled = true;
    }

    private void UpdateSearchVisibility()
    {
        SearchClear.Visibility = SearchBox.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---- batch mode ---------------------------------------------------------------------------

    private void OnBatchToggleClick(object sender, RoutedEventArgs e) => ToggleBatchMode();

    private void ToggleBatchMode()
    {
        _batchMode = !_batchMode;
        _batchSelection.Clear();
        if (_batchMode && _selectedItemId is { } id)
        {
            _batchSelection.Add(id);
        }
        Rebuild();
    }

    private void UpdateFooter()
    {
        FooterNormal.Children.Clear();
        FooterBatch.Children.Clear();
        FooterNormal.Visibility = _batchMode ? Visibility.Collapsed : Visibility.Visible;
        FooterBatch.Visibility = _batchMode ? Visibility.Visible : Visibility.Collapsed;

        if (_batchMode)
        {
            FooterBatch.Children.Add(NewFooterButton(L10n.T("panel.batch_select_all"), () =>
            {
                foreach (var row in _flatRows)
                {
                    _batchSelection.Add(row.Item.Id);
                }
                Rebuild();
            }));
            FooterBatch.Children.Add(NewFooterButton(L10n.T("panel.batch_clear_selection"), () =>
            {
                _batchSelection.Clear();
                Rebuild();
            }));
            var allFavorited = _batchSelection.Count > 0
                               && _flatRows.Where(r => _batchSelection.Contains(r.Item.Id)).All(r => r.Item.IsFavorite);
            FooterBatch.Children.Add(NewFooterButton(
                allFavorited ? L10n.T("panel.batch_unfavorite_selected") : L10n.T("panel.batch_favorite_selected"),
                () =>
                {
                    var ids = _batchSelection.ToList();
                    var favorite = !allFavorited;
                    _app.Store.SetFavorites(ids, favorite);
                    _app.Toast.Show(L10n.Format(
                        favorite ? "panel.batch_favorite_success" : "panel.batch_unfavorite_success", ids.Count));
                }));
            FooterBatch.Children.Add(NewFooterButton(L10n.T("panel.batch_delete_selected"), () =>
            {
                var count = _batchSelection.Count;
                _app.Store.DeleteItems(_batchSelection.ToList());
                _batchSelection.Clear();
                _app.Toast.Show(L10n.Format("panel.batch_delete_success", count));
                if (_flatRows.Count == 0)
                {
                    _batchMode = false;
                }
            }, danger: true));
            FooterBatch.Children.Add(NewFooterButton(L10n.T("panel.batch_done"), () =>
            {
                _batchMode = false;
                _batchSelection.Clear();
                Rebuild();
            }));
        }
        else
        {
            var primaryLabel = _popoverMode
                ? L10n.T("menu.copy_selected")
                : _app.Settings.AutoPasteEnabled
                    ? L10n.T("panel.paste_selected")
                    : L10n.T("menu.copy_selected");
            FooterNormal.Children.Add(NewFooterButton(primaryLabel, () =>
            {
                if (SelectedRow is { } row)
                {
                    RunPrimaryAction(row.Item);
                }
            }));
            FooterNormal.Children.Add(NewFooterButton(L10n.T("menu.copy"), () =>
            {
                if (SelectedRow is { } row)
                {
                    _app.Coordinator.CopyOnly(row.Item);
                }
            }));
            if (_popoverMode)
            {
                FooterNormal.Children.Add(NewFooterButton(L10n.T("menu.open_panel"), () =>
                {
                    CloseRequested?.Invoke();
                    _app.Coordinator.ShowPanel();
                }));
                FooterNormal.Children.Add(NewFooterButton(L10n.T("menu.preferences"), () =>
                {
                    CloseRequested?.Invoke();
                    _app.Coordinator.ShowSettings();
                }));
                FooterNormal.Children.Add(NewFooterButton(L10n.T("menu.quit"), () => _app.Quit()));
            }
        }
    }

    private Button NewFooterButton(string text, Action onClick, bool danger = false)
    {
        var button = new Button
        {
            Style = (Style)FindResource("CapsuleButton"),
            Content = text,
            Margin = new Thickness(0, 0, 8, 0),
        };
        if (danger)
        {
            button.Foreground = (Brush)FindResource("Danger");
        }
        button.Click += (_, _) => onClick();
        return button;
    }

    // ---- header buttons -------------------------------------------------------------------------

    private void OnStatsClick(object sender, RoutedEventArgs e) => _app.Coordinator.ShowStatistics();
    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        CancelPendingPrimaryAction();
        CloseRequested?.Invoke();
    }

    // ---- context menu ------------------------------------------------------------------------------

    private ContextMenu BuildRowContextMenu(ClipboardItem item)
    {
        var menu = new ContextMenu();
        AddMenuItem(menu, "\uE8C8", L10n.T("menu.copy"), () => _app.Coordinator.CopyOnly(item));

        if (item.IsFileCollection)
        {
            AddMenuItem(menu, "\uE838", item.OpenActionTitle, () => OpenItem(item));
            if (item.IsSingleFile)
            {
                AddMenuItem(menu, "\uE8AD", L10n.T("menu.reveal_in_explorer"), () =>
                    _app.Coordinator.RevealInExplorer(new[] { item.SingleFilePath! }));
            }
            AddMenuItem(menu, "\uE8C4", L10n.T("menu.copy_path"), () =>
                _app.Coordinator.CopyPaths(item.Content.FilePaths ?? Array.Empty<string>()));
            AddMenuItem(menu, "\uE74E", L10n.T("menu.save_as"), () => RunSaveAs(item));
        }

        if (item.IsUrl)
        {
            AddMenuItem(menu, "\uE774", L10n.T("menu.open_in_browser"), () =>
                _app.Coordinator.OpenInBrowser(item.BrowserUrl));
            AddMenuItem(menu, "\uE8C4", L10n.T("menu.copy_link"), () => _app.Coordinator.CopyOnly(item));
        }

        if (item.IsEmail)
        {
            AddMenuItem(menu, "\uE715", L10n.T("menu.open_email"), () =>
                _app.Coordinator.OpenEmail(item.MailtoUrl));
        }

        if (item.IsImage)
        {
            AddMenuItem(menu, "\uE91B", L10n.T("preview.open_image"), () => _app.Coordinator.OpenPreview(item));
            AddMenuItem(menu, "\uE74E", L10n.T("menu.save_as"), () => RunSaveAs(item));
        }

        if (item.SupportsTextPreview)
        {
            AddMenuItem(menu, "\uE90F", L10n.T("preview.text_title"), () => _app.Coordinator.OpenPreview(item));
        }

        AddMenuItem(menu,
            item.IsFavorite ? "\uE718" : "\uE735",
            item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite"),
            () => _app.Store.SetFavorite(item, !item.IsFavorite));

        AddMenuItem(menu, "\uE74D", L10n.T("menu.delete"), () => _app.Store.DeleteItem(item), danger: true);
        return menu;
    }

    private void OpenItem(ClipboardItem item) =>
        _app.Coordinator.OpenPaths(item.Content.FilePaths ?? Array.Empty<string>());

    private void RunSaveAs(ClipboardItem item)
    {
        if (item.IsImage)
        {
            SaveAsService.SaveImage(null, item);
        }
        else if (item.Content.FilePaths is { Count: 1 } single)
        {
            SaveAsService.SaveSingleFile(null, single[0]);
        }
        else if (item.Content.FilePaths is { Count: > 1 } many)
        {
            SaveAsService.SaveMultipleFiles(null, many);
        }
    }

    private static void AddMenuItem(ContextMenu menu, string glyph, string header, Action onClick, bool danger = false)
    {
        var item = new MenuItem
        {
            Header = header,
            Icon = new TextBlock { Text = glyph, FontSize = 11 },
            Foreground = danger ? new SolidColorBrush(Color.FromRgb(0xE0, 0x45, 0x3A)) : null,
        };
        item.Click += (_, _) => onClick();
        menu.Items.Add(item);
    }

    // ---- icons ---------------------------------------------------------------------------

    private static string IconGlyphFor(ClipboardItem item) =>
        item switch
        {
            _ when item.IsEmail => "\uE715",
            _ when item.IsUrl => "\uE71B",
            _ when item.IsCode => "\uE943",
            _ when item.IsFileCollection && item.ContainsFolders => "\uE8B7",
            _ when item.IsFileCollection => "\uE8A5",
            _ => "\uE8D2",
        };

    private static Brush IconBrushFor(ClipboardItem item)
    {
        var color = item switch
        {
            _ when item.IsEmail => Color.FromRgb(0x1A, 0x6B, 0xE8),
            _ when item.IsUrl => Color.FromRgb(0x1F, 0xA3, 0xD1),
            _ when item.IsCode => Color.FromRgb(0x87, 0x63, 0xC9),
            _ when item.IsFileCollection && item.ContainsFolders => Color.FromRgb(0xE0, 0xA3, 0x29),
            _ when item.IsFileCollection => Color.FromRgb(0x1F, 0x9E, 0x8C),
            _ => Color.FromRgb(0x8A, 0x8A, 0x8E),
        };
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
