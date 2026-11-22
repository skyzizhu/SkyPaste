#!/usr/bin/env python3
"""Convert remaining tool windows to WPF-UI FluentWindow + TitleBar.

Pattern per window:
- <Window ... WindowStyle="ToolWindow"> -> <ui:FluentWindow ... ExtendsContentIntoTitleBar/Backdrop>
- wrap original root content: <Grid><ui:TitleBar .../><Grid Grid.Row=1>original</Grid></Grid>
- code-behind: base class -> Wpf.Ui.Controls.FluentWindow
"""
import sys

UI_NS = 'xmlns:ui="http://schemas.lepo.co/wpfui/2022/xaml"'

WINDOWS = [
    # (xaml path, class, title, titlebar title binding, root grid attrs)
    ("src/SkyPaste/Views/StatisticsWindow.xaml", "SkyPaste.StatisticsWindow", "Clipboard Insights", True, 'Margin="18,4,18,14"'),
    ("src/SkyPaste/Views/ImagePreviewWindow.xaml", "SkyPaste.ImagePreviewWindow", "Image Preview", True, ""),
    ("src/SkyPaste/Views/TextPreviewWindow.xaml", "SkyPaste.TextPreviewWindow", "Text Preview", True, ""),
    ("src/SkyPaste/Views/FilePreviewWindow.xaml", "SkyPaste.FilePreviewWindow", "Item Details", True, ""),
    ("src/SkyPaste/Views/DebugWindow.xaml", "SkyPaste.DebugWindow", "Pasteboard Debug", True, 'Margin="14,4,14,12"'),
]

def convert(xaml_path, class_name, title):
    s = open(xaml_path, encoding="utf-8").read()

    # 1) root element
    old_open = '<Window x:Class="' + class_name + '"'
    if old_open not in s:
        print(f"SKIP (root not Window): {xaml_path}")
        return False
    # find the end of the opening tag
    open_end = s.find(">", old_open)
    open_tag = s[old_open:open_end]
    # extract inner attrs to carry over (all except class/windowstyle already handled)
    inner = open_tag.replace('<Window x:Class="' + class_name + '"', "").strip()
    # drop WindowStyle attr if present
    import re
    inner = re.sub(r'\s*WindowStyle="[^"]*"', "", inner)

    new_open = '<ui:FluentWindow x:Class="' + class_name + '"\n        ' + UI_NS + "\n        " + inner.strip() + '\n        ExtendsContentIntoTitleBar="True"\n        WindowBackdropType="Mica">'
    s = s[:old_open] + new_open + s[open_end + 1:]
    s = s.replace("</Window>", "</ui:FluentWindow>")

    # 2) wrap content with Grid + TitleBar
    # find the first child element after the opening tag
    first_child = s.find(">", new_open and s.find(new_open))  # first '>' after new open tag
    first_child = s.find(">", s.find(new_open))
    content_start = s.find(">", s.find('<ui:FluentWindow')) + 1
    # Insert: <Grid> <ui:TitleBar/> <Grid Grid.Row=1> ... original ... </Grid> </Grid>
    titlebar = (
        '\n    <Grid>' + chr(10)
        + '        <Grid.RowDefinitions>' + chr(10)
        + '            <RowDefinition Height="Auto" />' + chr(10)
        + '            <RowDefinition Height="*" />' + chr(10)
        + '        </Grid.RowDefinitions>' + chr(10)
        + '        <ui:TitleBar Grid.Row="0" Title="' + title + '"'
        + ' Title="{Binding RelativeSource={RelativeSource AncestorType=Window}, Path=Title}"'
        + ' ShowMaximize="True" ShowMinimize="False" />' + chr(10)
        + '        <Grid Grid.Row="1">'
    )
    closing = chr(10) + '        </Grid>' + chr(10) + '    </Grid>'
    s = s[:content_start] + titlebar + s[content_start:] + closing

    open(xaml_path, "w", encoding="utf-8").write(s)
    return True

# code-behind base class swaps
CODE = [
    ("src/SkyPaste/Views/StatisticsWindow.xaml.cs", "public partial class StatisticsWindow : Window"),
    ("src/SkyPaste/Views/ImagePreviewWindow.xaml.cs", "public partial class ImagePreviewWindow : Window"),
    ("src/SkyPaste/Views/TextPreviewWindow.xaml.cs", "public partial class TextPreviewWindow : Window"),
    ("src/SkyPaste/Views/FilePreviewWindow.xaml.cs", "public partial class FilePreviewWindow : Window"),
    ("src/SkyPaste/Views/DebugWindow.xaml.cs", "public partial class DebugWindow : Window"),
]

ok = 0
for xaml, cls, title, bind, _ in WINDOWS:
    if convert(xaml, cls, title):
        ok += 1

for path, old in CODE:
    s = open(path, encoding="utf-8").read()
    assert old in s, (path, old)
    s = s.replace(old, old.replace(": Window", ": Wpf.Ui.Controls.FluentWindow"), 1)
    # drop EnableRoundedCorners calls (FluentWindow handles backdrop/rounding)
    s = s.replace("        WindowEffectsService.EnableRoundedCorners(this);\n", "")
    s = s.replace("        Loaded += (_, _) =>\n        {\n            WindowEffectsService.EnableRoundedCorners(this);\n            Refresh();\n        };",
                  "        Loaded += (_, _) => Refresh();")
    open(path, "w", encoding="utf-8").write(s)

print(f"converted {ok}/{len(WINDOWS)} windows")
