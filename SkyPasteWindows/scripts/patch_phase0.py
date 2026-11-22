#!/usr/bin/env python3
"""Phase 0 fixes: tool-window ownership/taskbar behavior, statistics cast bug,
exception logging, misc cleanups. Purely behavioral - no restyling yet."""

def patch(path, old, new):
    s = open(path, encoding="utf-8").read()
    assert old in s, (path, old[:70])
    open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))

changes = []

# ---- 1) AppCoordinator: ownership helper -------------------------------
p = "src/SkyPaste/AppCoordinator.cs"
patch(p,
"""    public void ShowSettings()
    {
        if (_settingsWindow is { Visibility: Visibility.Visible })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_app);
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }""",
"""    /// <summary>
    /// Tool windows are owned by the main panel (when visible) so they can
    /// never be buried under the always-on-top panel - the previous cause of
    /// 'Preferences opens but is invisible'.
    /// </summary>
    private System.Windows.Window? ToolOwner =>
        _mainWindow is { Visibility: System.Windows.Visibility.Visible } ? _mainWindow : null;

    public void ShowSettings()
    {
        if (_settingsWindow is { Visibility: Visibility.Visible })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_app) { Owner = ToolOwner };
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }""")
changes.append(("AppCoordinator.cs", "ownership helper + settings owner"))

patch(p,
"""        _statisticsWindow = new StatisticsWindow(_app);
        _statisticsWindow.Show();""",
"""        _statisticsWindow = new StatisticsWindow(_app) { Owner = ToolOwner };
        _statisticsWindow.Show();""")
patch(p,
"""        _debugWindow = new DebugWindow(_app);
        _debugWindow.Show();""",
"""        _debugWindow = new DebugWindow(_app) { Owner = ToolOwner };
        _debugWindow.Show();""")
patch(p,
"""        var window = new ImagePreviewWindow(_app, full);
        window.Show();""",
"""        var window = new ImagePreviewWindow(_app, full) { Owner = ToolOwner };
        window.Show();""")
patch(p,
"""        var window = new TextPreviewWindow(_app, item);
        window.Show();""",
"""        var window = new TextPreviewWindow(_app, item) { Owner = ToolOwner };
        window.Show();""")
patch(p,
"""        var window = new FilePreviewWindow(_app, item);
        window.Show();""",
"""        var window = new FilePreviewWindow(_app, item) { Owner = ToolOwner };
        window.Show();""")
changes.append(("AppCoordinator.cs", "owners for statistics/debug/previews"))

# ---- 2) Tool windows: standard behavior --------------------------------
p = "src/SkyPaste/Views/SettingsWindow.xaml"
patch(p,
'''        Title="Preferences" WindowStyle="ToolWindow">''',
'''        Title="Preferences">''')
p = "src/SkyPaste/Views/SettingsWindow.xaml.cs"
patch(p,
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;""",
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        ShowActivated = true;""")
changes.append(("SettingsWindow", "standard window"))

p = "src/SkyPaste/Views/StatisticsWindow.xaml"
patch(p,
'''        Title="Clipboard Insights" WindowStyle="ToolWindow">''',
'''        Title="Clipboard Insights">''')
p = "src/SkyPaste/Views/StatisticsWindow.xaml.cs"
patch(p,
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;""",
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;""")

p = "src/SkyPaste/Views/StatisticsWindow.xaml"
patch(p,
'''            <Button Tag="0" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0" Content="Today" />
            <Button Tag="1" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0" Content="7 days" />
            <Button Tag="2" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0" Content="30 days" />
            <Button Tag="3" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0" Content="6 months" />
            <Button Tag="4" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Content="1 year" />''',
'''            <Button Tag="0" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0">
                <TextBlock Text="Today" />
            </Button>
            <Button Tag="1" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0">
                <TextBlock Text="7 days" />
            </Button>
            <Button Tag="2" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0">
                <TextBlock Text="30 days" />
            </Button>
            <Button Tag="3" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}" Margin="0,0,6,0">
                <TextBlock Text="6 months" />
            </Button>
            <Button Tag="4" Click="OnPeriodClick" Style="{DynamicResource CapsuleButton}">
                <TextBlock Text="1 year" />
            </Button>''')
p = "src/SkyPaste/Views/StatisticsWindow.xaml.cs"
patch(p,
"""            var selected = (StatisticsPeriod)int.Parse((string)child.Tag, CultureInfo.InvariantCulture);
            ((TextBlock)child.Content).Text = PeriodLabel(selected);""",
"""            var selected = (StatisticsPeriod)int.Parse((string)child.Tag, CultureInfo.InvariantCulture);
            if (child.Content is TextBlock textBlock)
            {
                textBlock.Text = PeriodLabel(selected);
            }
            else
            {
                child.Content = PeriodLabel(selected);
            }""")
changes.append(("StatisticsWindow", "standard window + cast fix + TextBlock content"))

p = "src/SkyPaste/Views/ImagePreviewWindow.xaml"
patch(p,
'''        Title="Image Preview" WindowStyle="ToolWindow">''',
'''        Title="Image Preview">''')
p = "src/SkyPaste/Views/ImagePreviewWindow.xaml.cs"
patch(p,
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;""",
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;""")
changes.append(("ImagePreviewWindow", "standard window"))

p = "src/SkyPaste/Views/TextPreviewWindow.xaml"
patch(p,
'''        Title="Text Preview" WindowStyle="ToolWindow">''',
'''        Title="Text Preview">''')
p = "src/SkyPaste/Views/TextPreviewWindow.xaml.cs"
patch(p,
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;""",
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;""")
changes.append(("TextPreviewWindow", "standard window"))

p = "src/SkyPaste/Views/FilePreviewWindow.xaml"
patch(p,
'''        Title="Item Details" WindowStyle="ToolWindow">''',
'''        Title="Item Details">''')
p = "src/SkyPaste/Views/FilePreviewWindow.xaml.cs"
patch(p,
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;""",
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;""")
changes.append(("FilePreviewWindow", "standard window"))

p = "src/SkyPaste/Views/DebugWindow.xaml"
patch(p,
'''        Title="Pasteboard Debug" WindowStyle="ToolWindow">''',
'''        Title="Pasteboard Debug">''')
p = "src/SkyPaste/Views/DebugWindow.xaml.cs"
patch(p,
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;""",
"""        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;""")
patch(p,
"""        Loaded += (_, _) =>
        {
            WindowEffectsService.EnableRoundedCorners(this);
            Refresh();
        };
        Loaded += (_, _) => WindowEffectsService.EnableRoundedCorners(this);""",
"""        Loaded += (_, _) =>
        {
            WindowEffectsService.EnableRoundedCorners(this);
            Refresh();
        };""")
changes.append(("DebugWindow", "standard window + dedupe"))

# ---- 3) Exception logging instead of silent swallow --------------------
p = "src/SkyPaste/App.xaml.cs"
patch(p,
"""        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
        };""",
"""        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
            try
            {
                var logDir = System.IO.Path.Combine(
                    AppSettingsService.DefaultDirectory, "logs");
                System.IO.Directory.CreateDirectory(logDir);
                var file = System.IO.Path.Combine(
                    logDir, $"ui-{DateTime.Now:yyyyMMdd}.log");
                System.IO.File.AppendAllText(file,
                    $"[{DateTime.Now:HH:mm:ss}] {args.Exception}\\n\\n");
            }
            catch
            {
                // Logging must never throw.
            }
        };""")
changes.append(("App.xaml.cs", "exception logging"))

# ---- 4) Monospace fonts --------------------------------------------------
for f in ["src/SkyPaste/Views/Controls/ClipboardListPanel.xaml.cs",
          "src/SkyPaste/Views/ImagePreviewWindow.xaml.cs",
          "src/SkyPaste/Views/FilePreviewWindow.xaml.cs",
          "src/SkyPaste/Views/DebugWindow.xaml",
          "src/SkyPaste/Views/FilePreviewWindow.xaml",
          "src/SkyPaste/Views/SettingsWindow.xaml"]:
    s = open(f, encoding="utf-8").read()
    if "Consolas, Menlo, monospace" in s:
        s = s.replace("Consolas, Menlo, monospace", "Cascadia Mono, Consolas")
        open(f, "w", encoding="utf-8").write(s)
    if '"Consolas, monospace"' in s:
        s = s.replace('"Consolas, monospace"', '"Cascadia Mono, Consolas"')
        open(f, "w", encoding="utf-8").write(s)
changes.append(("various", "monospace -> Cascadia Mono"))

# ---- 5) Remove dead AddSectionCard ---------------------------------------
p = "src/SkyPaste/Views/Controls/ClipboardListPanel.xaml.cs"
s = open(p, encoding="utf-8").read()
start = s.find("    private void AddSectionCard(")
if start != -1:
    end = s.find("\n    }", start) + len("\n    }")
    s = s[:start] + s[end:].lstrip("\n")
    open(p, "w", encoding="utf-8").write(s)
    changes.append(("ClipboardListPanel.xaml.cs", "dead AddSectionCard removed"))

print("Phase-0 changes:")
for f, what in changes:
    print(f"  {f}: {what}")
