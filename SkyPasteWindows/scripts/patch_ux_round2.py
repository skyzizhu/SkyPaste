#!/usr/bin/env python3
"""Second real-device feedback round:
1. Tray popover header: remove the close glyph button (Esc / outside click /
   tray toggle already close it).
2. Source-app filter button ('Apps'): icon only, no text.
3. Click semantics like the Mac App Store build: single click only SELECTS
   (auto-copy default OFF); right-click also selects the row and opens the
   context menu."""

def patch(path, old, new):
    s = open(path, encoding="utf-8").read()
    assert old in s, (path, old[:70])
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))

# ---- 1) popover close button removed (all modes) ----
p = "src/SkyPaste/Views/Controls/ClipboardListPanel.xaml.cs"
patch(p,
"""        if (popoverMode)
        {
            BatchToggle.Visibility = Visibility.Collapsed;
            CloseToggle.Visibility = Visibility.Visible;
            StatsToggle.Visibility = Visibility.Visible;
            // Popover has no TitleBar: keep the brand block visible.
            BrandLogo.Visibility = Visibility.Visible;
            HeaderTitle.Visibility = Visibility.Visible;
        }
        else
        {
            StatsToggle.Visibility = Visibility.Collapsed;
            // Main panel: TitleBar already shows the app identity and the X
            // caption button hides the panel.
            CloseToggle.Visibility = Visibility.Collapsed;
            BrandLogo.Visibility = Visibility.Collapsed;
            HeaderTitle.Visibility = Visibility.Collapsed;
        }""",
"""        // No in-header close button on any surface: the main panel closes via
        // its TitleBar X / Esc, the popover via Esc / outside click / tray.
        BatchToggle.Visibility = popoverMode ? Visibility.Collapsed : Visibility.Visible;
        CloseToggle.Visibility = Visibility.Collapsed;
        StatsToggle.Visibility = popoverMode ? Visibility.Visible : Visibility.Collapsed;
        // Popover has no TitleBar: keep the brand block visible.
        BrandLogo.Visibility = popoverMode ? Visibility.Visible : Visibility.Collapsed;
        HeaderTitle.Visibility = popoverMode ? Visibility.Visible : Visibility.Collapsed;""")

# ---- 2) source-app button: icon only ----
patch(p,
"""        SourceMenuLabel.Text = _sourceSelection.Kind switch""",
"""        SourceMenuLabel.Visibility = Visibility.Collapsed; // icon-only button
        SourceMenuLabel.Text = _sourceSelection.Kind switch""")
patch(p,
"""                    <TextBlock x:Name="SourceMenuGlyph" Text="&#xE8A9;" FontSize="11" />
                    <TextBlock x:Name="SourceMenuLabel" Margin="5,0,0,0" Text="Apps" FontSize="11" />""",
"""                    <TextBlock x:Name="SourceMenuGlyph" Text="&#xE8A9;" FontSize="12" />
                    <TextBlock x:Name="SourceMenuLabel" Margin="5,0,0,0" Text="Apps" FontSize="11" Visibility="Collapsed" />""", False)

# XAML lives in the .xaml file; patch that instead for the label default
p = "src/SkyPaste/Views/Controls/ClipboardListPanel.xaml"
patch(p,
'''                    <TextBlock x:Name="SourceMenuGlyph" Text="&#xE8A9;" FontSize="11" />
                    <TextBlock x:Name="SourceMenuLabel" Margin="5,0,0,0" Text="Apps" FontSize="11" />''',
'''                    <TextBlock x:Name="SourceMenuGlyph" Text="&#xE8A9;" FontSize="12" />
                    <TextBlock x:Name="SourceMenuLabel" Margin="5,0,0,0" Text="Apps" FontSize="11" Visibility="Collapsed" />''')

# ---- 3a) auto-copy default OFF (Mac App Store default) ----
p = "src/SkyPaste.Core/Services/AppSettingsService.cs"
patch(p,
"""    private bool _autoPasteEnabled = true;
    public bool AutoPasteEnabled""",
"""    private bool _autoPasteEnabled;
    public bool AutoPasteEnabled""")
patch(p,
"""        public bool LaunchAtLogin { get; set; } = true;
        public bool AutoPasteEnabled { get; set; } = true;""",
"""        public bool LaunchAtLogin { get; set; } = true;
        public bool AutoPasteEnabled { get; set; }""")

# ---- 3b) right-click also selects the row (non-batch mode) ----
p = "src/SkyPaste/Views/Controls/ClipboardListPanel.xaml.cs"
patch(p,
"""        border.MouseDown += (_, e) =>
        {
            if (e.ChangedButton == MouseButton.Left)
            {
                SelectRow(item.Id);
            }
        };""",
"""        border.MouseDown += (_, e) =>
        {
            if (_batchMode)
            {
                // Batch mode: only left-click toggles the check state.
                if (e.ChangedButton == MouseButton.Left)
                {
                    SelectRow(item.Id);
                }
            }
            else
            {
                // Any button selects the row (right-click selects + opens the
                // context menu, like Windows list conventions / the Mac app).
                SelectRow(item.Id);
            }
        };""")

# ---- tests: update defaults expectation ----
p = "tests/SkyPaste.Tests/AppSettingsServiceTests.cs"
patch(p,
"""        Assert.True(settings.AutoPasteEnabled);""",
"""        Assert.False(settings.AutoPasteEnabled); // Mac App Store default: click only selects""")

print("OK")
