using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;

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
        Width = 960;
        Height = 680;
        MinWidth = 700;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        Background = (Brush)FindResource("Window.Background");

        CopyLabel.Text = item.IsUrl ? L10n.T("menu.copy_link") : L10n.T("menu.copy");
        FavoriteLabel.Text = item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
        EmailLabel.Text = L10n.T("menu.open_email");
        BrowserLabel.Text = L10n.T("menu.open_in_browser");

        var text = item.TextValue ?? string.Empty;
        PreviewText.Text = text;
        if (item.IsCode)
        {
            PreviewText.FontFamily = new FontFamily("Consolas, Menlo, monospace");
        }

        BrowserButton.Visibility = item.IsUrl ? Visibility.Visible : Visibility.Collapsed;
        EmailButton.Visibility = item.IsEmail ? Visibility.Visible : Visibility.Collapsed;

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };
    }

    private void OnCopy(object sender, RoutedEventArgs e) => _app.Coordinator.CopyOnly(_item);

    private void OnOpenBrowser(object sender, RoutedEventArgs e) =>
        _app.Coordinator.OpenInBrowser(_item.BrowserUrl);

    private void OnOpenEmail(object sender, RoutedEventArgs e) =>
        _app.Coordinator.OpenEmail(_item.MailtoUrl);

    private void OnFavorite(object sender, RoutedEventArgs e)
    {
        _app.Store.SetFavorite(_item, !_item.IsFavorite);
        FavoriteLabel.Text = _item.IsFavorite ? L10n.T("menu.unfavorite") : L10n.T("menu.favorite");
    }
}
