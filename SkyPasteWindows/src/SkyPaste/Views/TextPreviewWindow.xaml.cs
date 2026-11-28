using System.Windows;
using System.Windows.Controls;
using SkyPaste.Views.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;

using SkyPaste.Services;

namespace SkyPaste;

/// <summary>Text/URL/email/code preview (mac TextPreviewView): selectable text, copy, browser/email open.</summary>
public partial class TextPreviewWindow : Window
{
    private readonly App _app;
    private readonly ClipboardItem _item;

    public TextPreviewWindow(App app, ClipboardItem item)
    {
        InitializeComponent();
        _app = app;
        _item = item;
        Title = item.IsEmail ? L10n.T("preview.email_title")
            : item.IsUrl ? L10n.T("preview.url_title")
            : item.IsCode ? L10n.T("preview.code_title")
            : L10n.T("preview.text_title");
        PreviewTitle.Text = Title;
        PreviewSource.Content = SourceIcon.CreatePreviewLabel(item);
        Width = 960;
        Height = 680;
        MinWidth = 700;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        SetResourceReference(BackgroundProperty, "Window.Background");

        CopyLabel.Text = item.IsUrl ? L10n.T("menu.copy_link") : L10n.T("menu.copy");
        FavoriteLabel.Text = item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
        EmailLabel.Text = L10n.T("menu.open_email");
        BrowserLabel.Text = L10n.T("menu.open_in_browser");
        ShareLabel.Text = L10n.T("menu.share");
        TranslateLabel.Text = L10n.T("menu.translate");
        TranslateButton.Visibility = AppCoordinator.CanTranslate(item) ? Visibility.Visible : Visibility.Collapsed;

        var text = item.TextValue ?? string.Empty;
        PreviewText.Text = text;
        if (item.IsCode)
        {
            PreviewText.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            PreviewText.FontSize = 13;
        }

        BrowserButton.Visibility = item.BrowserUrl is not null ? Visibility.Visible : Visibility.Collapsed;
        EmailButton.Visibility = item.MailtoUrl is not null ? Visibility.Visible : Visibility.Collapsed;

        Loaded += (_, _) => WindowEffectsService.EnableRoundedCorners(this);
        Activated += (_, _) => UpdateFavoriteLabel();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };
    }

    private void OnCopy(object sender, RoutedEventArgs e) => _app.Coordinator.CopyOnly(_item);

    private void OnShare(object sender, RoutedEventArgs e) => _app.Coordinator.Share(this, _item);

    private void OnTranslate(object sender, RoutedEventArgs e) => _app.Coordinator.OpenTranslator(_item);

    private void OnOpenBrowser(object sender, RoutedEventArgs e) =>
        _app.Coordinator.OpenInBrowser(_item.BrowserUrl);

    private void OnOpenEmail(object sender, RoutedEventArgs e) =>
        _app.Coordinator.OpenEmail(_item.MailtoUrl);

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        _app.Store.SetFavorite(_item, !_app.Store.IsFavorite(_item));
        UpdateFavoriteLabel();
    }

    private void UpdateFavoriteLabel() =>
        FavoriteLabel.Text = _app.Store.IsFavorite(_item) ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
}
