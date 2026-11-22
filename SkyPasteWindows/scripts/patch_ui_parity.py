#!/usr/bin/env python3
"""UI parity batch B: hover state, ctrl+c badge on selected row, batch stars
coexisting with checkbox + in-place toggle, startup notice banner, source-app
icon badge, icon color alignment."""

def patch(path, old, new):
    s = open(path, encoding="utf-8").read()
    assert old in s, (path, old[:70])
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))

p = "src/SkyPaste/Views/Controls/ClipboardListPanel.xaml.cs"

# hover state
patch(p,
"""        border.MouseDown += (_, e) =>
        {""",
"""        border.MouseEnter += (_, _) =>
        {
            if (_selectedItemId != item.Id)
            {
                border.Background = (System.Windows.Media.Brush)FindResource("Row.Hover");
            }
        };
        border.MouseLeave += (_, _) => UpdateRowVisual(item.Id);
        border.MouseDown += (_, e) =>
        {""")

# selected badge: ctrl+c hint on selected rows
patch(p,
"""        var tailStack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
        };""",
"""        var tailStack = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
        };
        if (!_batchMode && _selectedItemId == item.Id)
        {
            // Mac: selected rows carry a small 'ctrl+c copy' hint.
            tailStack.Children.Add(new TextBlock
            {
                Text = L10n.T("menu.command_c_copy"),
                FontSize = 8.5,
                Foreground = (System.Windows.Media.Brush)FindResource("Text.Secondary"),
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, 6, 0),
            });
        }""")

# batch: stars AND checkbox coexist
patch(p,
"""        if (_batchMode)
        {
            tailStack.Children.Add(new TextBlock
            {
                Name = "BatchGlyph",
                Text = _batchSelection.Contains(item.Id) ? "\\uE73E" : "\\uE739",
                FontSize = 13,
                Foreground = _batchSelection.Contains(item.Id)
                    ? (Brush)FindResource("AccentBrush")
                    : (Brush)FindResource("Text.Secondary"),
            });
        }
        else if (item.IsFavorite)""",
"""        if (_batchMode)
        {
            if (item.IsFavorite)
            {
                tailStack.Children.Add(new TextBlock
                {
                    Text = "\\uE735",
                    FontSize = 11,
                    Foreground = (Brush)FindResource("Favorite"),
                });
            }
            tailStack.Children.Add(new TextBlock
            {
                Name = "BatchGlyph",
                Text = _batchSelection.Contains(item.Id) ? "\\uE73E" : "\\uE739",
                FontSize = 13,
                Foreground = _batchSelection.Contains(item.Id)
                    ? (Brush)FindResource("AccentBrush")
                    : (Brush)FindResource("Text.Secondary"),
            });
        }
        else if (item.IsFavorite)""")

# in-place batch toggle (keeps scroll position)
patch(p,
"""        if (_batchMode && id is { } batchId)
        {
            if (!_batchSelection.Add(batchId))
            {
                _batchSelection.Remove(batchId);
            }
            Rebuild();
            return;
        }""",
"""        if (_batchMode && id is { } batchId)
        {
            if (!_batchSelection.Add(batchId))
            {
                _batchSelection.Remove(batchId);
            }
            if (_rowBorders.TryGetValue(batchId, out var border))
            {
                foreach (var glyph in FindVisualChildren<TextBlock>(border)
                    .Where(t => t.Text == "\\uE73E" || t.Text == "\\uE739"))
                {
                    glyph.Text = _batchSelection.Contains(batchId) ? "\\uE73E" : "\\uE739";
                    glyph.Foreground = _batchSelection.Contains(batchId)
                        ? (System.Windows.Media.Brush)FindResource("AccentBrush")
                        : (System.Windows.Media.Brush)FindResource("Text.Secondary");
                }
            }
            UpdateFooter();
            return;
        }""")

# helper
patch(p,
"    private static string IconGlyphFor(ClipboardItem item) =>",
"""    private static System.Collections.Generic.IEnumerable<T> FindVisualChildren<T>(System.Windows.DependencyObject root)
        where T : System.Windows.DependencyObject
    {
        var count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            if (child is T typed)
            {
                yield return typed;
            }
            foreach (var descendant in FindVisualChildren<T>(child))
            {
                yield return descendant;
            }
        }
    }

    private static string IconGlyphFor(ClipboardItem item) =>""")

# XAML: startup notice banner + row shifts
p = "src/SkyPaste/Views/Controls/ClipboardListPanel.xaml"
patch(p,
'        <!-- Search field -->\n        <Border x:Name="SearchBar" Grid.Row="1"',
'''        <!-- Startup notice banner (mac startupNotice) -->
        <Border x:Name="StartupNoticeBar" Grid.Row="1" Margin="16,10,16,0" CornerRadius="12"
                Background="{DynamicResource AccentSoftBrush}" Padding="12,8" Visibility="Collapsed">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="&#xE946;" FontFamily="{DynamicResource GlyphFont}"
                           FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0"
                           Foreground="{DynamicResource AccentBrush}" />
                <TextBlock x:Name="StartupNoticeText" Grid.Column="1" FontSize="11" TextWrapping="Wrap"
                           Foreground="{DynamicResource Text.Primary}" VerticalAlignment="Center" />
                <Button Grid.Column="2" Style="{DynamicResource IconIconButton}" Click="OnStartupNoticeClose">
                    <TextBlock Text="&#xE711;" FontSize="10" />
                </Button>
            </Grid>
        </Border>

        <!-- Search field -->
        <Border x:Name="SearchBar" Grid.Row="2"''')
patch(p, 'x:Name="SearchBar" Grid.Row="2"', 'x:Name="SearchBar" Grid.Row="2"')
s = open(p, encoding="utf-8").read()
s = s.replace('x:Name="SearchBar" Grid.Row="1"', 'x:Name="SearchBar" Grid.Row="2"')
s = s.replace('x:Name="FilterChips" Grid.Row="2"', 'x:Name="FilterChips" Grid.Row="3"')
s = s.replace('x:Name="ContentScroll" Grid.Row="3"', 'x:Name="ContentScroll" Grid.Row="4"')
s = s.replace('x:Name="FooterNormal" Grid.Row="4"', 'x:Name="FooterNormal" Grid.Row="5"')
s = s.replace('x:Name="FooterBatch" Grid.Row="4"', 'x:Name="FooterBatch" Grid.Row="5"')
open(p, "w", encoding="utf-8").write(s)

# code-behind: startup notice wiring + batch banner (panel feedback)
patch(p,
"""        Loaded += (_, _) => { RefreshLocalization(); RebuildChips(); Rebuild(); };""",
"""        Loaded += (_, _) => { RefreshLocalization(); RebuildChips(); Rebuild(); ShowStartupNotice(); };""")
patch(p,
"""    private static string FilterLabel(ClipboardFilter filter) => L10n.T(filter.LocalizationKey());""",
"""    private void ShowStartupNotice()
    {
        var notice = _app.Store.StartupNotice;
        if (string.IsNullOrEmpty(notice))
        {
            StartupNoticeBar.Visibility = Visibility.Collapsed;
            return;
        }
        StartupNoticeText.Text = notice;
        StartupNoticeBar.Visibility = Visibility.Visible;
    }

    private void OnStartupNoticeClose(object sender, RoutedEventArgs e)
    {
        StartupNoticeBar.Visibility = Visibility.Collapsed;
    }

    /// <summary>Mac batch feedback: an in-panel banner for ~1.7s.</summary>
    private DispatcherTimer? _batchBannerTimer;
    private void ShowBatchBanner(string text)
    {
        StartupNoticeText.Text = text;
        StartupNoticeBar.Visibility = Visibility.Visible;
        _batchBannerTimer?.Stop();
        _batchBannerTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1700) };
        _batchBannerTimer.Tick += (_, _) =>
        {
            _batchBannerTimer?.Stop();
            StartupNoticeBar.Visibility = Visibility.Collapsed;
        };
        _batchBannerTimer.Start();
    }

    private static string FilterLabel(ClipboardFilter filter) => L10n.T(filter.LocalizationKey());""")

# batch actions use the in-panel banner instead of the global toast
patch(p,
"""                    _app.Store.SetFavorites(ids, favorite);
                    _app.Toast.Show(L10n.Format(
                        favorite ? "panel.batch_favorite_success" : "panel.batch_unfavorite_success", ids.Count));""",
"""                    _app.Store.SetFavorites(ids, favorite);
                    ShowBatchBanner(L10n.Format(
                        favorite ? "panel.batch_favorite_success" : "panel.batch_unfavorite_success", ids.Count));""")
patch(p,
"""                _app.Store.DeleteItems(_batchSelection.ToList());
                _batchSelection.Clear();
                _app.Toast.Show(L10n.Format("panel.batch_delete_success", count));""",
"""                _app.Store.DeleteItems(_batchSelection.ToList());
                _batchSelection.Clear();
                ShowBatchBanner(L10n.Format("panel.batch_delete_success", count));""")

# merge SelectAll/Clear into one toggle button (Mac)
patch(p,
"""            FooterBatch.Children.Add(NewFooterButton(L10n.T("panel.batch_select_all"), () =>
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
            }));""",
"""            var allSelected = _flatRows.Count > 0
                              && _flatRows.All(r => _batchSelection.Contains(r.Item.Id));
            FooterBatch.Children.Add(NewFooterButton(
                allSelected ? L10n.T("panel.batch_clear_selection") : L10n.T("panel.batch_select_all"),
                () =>
                {
                    if (allSelected)
                    {
                        _batchSelection.Clear();
                    }
                    else
                    {
                        foreach (var row in _flatRows)
                        {
                            _batchSelection.Add(row.Item.Id);
                        }
                    }
                    Rebuild();
                }));""")

# icon colors align to Mac palette (code teal-green, file indigo, folder orange)
patch(p,
"""            _ when item.IsCode => Color.FromRgb(0x87, 0x63, 0xC9),
            _ when item.IsFileCollection && item.ContainsFolders => Color.FromRgb(0xE0, 0xA3, 0x29),
            _ when item.IsFileCollection => Color.FromRgb(0x1F, 0x9E, 0x8C),""",
"""            _ when item.IsCode => Color.FromRgb(0x1F, 0x9E, 0x8C),
            _ when item.IsFileCollection && item.ContainsFolders => Color.FromRgb(0xFF, 0x95, 0x00),
            _ when item.IsFileCollection => Color.FromRgb(0x58, 0x56, 0xD6),""")

print("OK: UI parity batch applied")
