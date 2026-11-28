using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using SkyPaste.Core.Core;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;

namespace SkyPaste.Views.Controls;

internal static class SourceIcon
{
    internal const string AllAppsGlyph = "\uE8A9";
    internal const string DeviceGlyph = "\uE717";

    internal static FrameworkElement Create(ClipboardSourceAppOption? app, double size, string fallbackGlyph)
    {
        var host = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };
        var fallback = new TextBlock
        {
            FontSize = size - 2,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (app is not null && !string.IsNullOrWhiteSpace(app.Name))
        {
            fallback.Text = StringInfo.GetNextTextElement(app.Name.TrimStart()).ToUpperInvariant();
            fallback.FontSize = size * 0.65;
            fallback.FontWeight = FontWeights.SemiBold;
            var background = new Border { CornerRadius = new CornerRadius(4) };
            background.SetResourceReference(Border.BackgroundProperty, "Row.Hover");
            host.Children.Add(background);
        }
        else
        {
            fallback.Text = fallbackGlyph;
            fallback.SetResourceReference(TextBlock.FontFamilyProperty, "GlyphFont");
        }
        host.Children.Add(fallback);
        if (app is not null)
        {
            host.Loaded += Load;
        }
        return host;

        async void Load(object sender, RoutedEventArgs args)
        {
            host.Loaded -= Load;
            try
            {
                var icon = await FileIconProvider.GetApplicationIconAsync(app!);
                if (icon is not null)
                {
                    host.Children.Clear();
                    host.Children.Add(new Image { Source = icon, Stretch = System.Windows.Media.Stretch.Uniform });
                }
            }
            catch (Exception error)
            {
                App.UiLog($"Source app icon unavailable: {error.GetType().Name}");
            }
        }
    }

    internal static FrameworkElement CreatePreviewLabel(ClipboardItem item)
    {
        var app = !item.Source.IsDeviceSynced() && item.SourceApp is { } source
            ? new ClipboardSourceAppOption(source.ProcessId, source.Name, source.ExecutablePath)
            : null;
        var label = new DockPanel { VerticalAlignment = VerticalAlignment.Center };
        var icon = Create(app, 14, item.Source.IsDeviceSynced() ? DeviceGlyph : "\uE7F4");
        icon.Margin = new Thickness(0, 0, 5, 0);
        label.Children.Add(icon);

        var sourceName = item.SourceApp?.Name ?? item.DeviceName ?? item.Source.BadgeText();
        var text = new TextBlock
        {
            Text = $"{L10n.T("preview.source_label")} {sourceName}",
            FontSize = 11,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        text.SetResourceReference(TextElement.ForegroundProperty, "Text.Secondary");
        label.Children.Add(text);
        return label;
    }
}
