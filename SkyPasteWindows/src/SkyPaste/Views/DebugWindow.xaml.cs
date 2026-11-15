using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SkyPaste.Core.Localization;
using SkyPaste.Services;

namespace SkyPaste;

/// <summary>Pasteboard debug panel (mac PasteboardDebugPanel): formats, decoded summary, preview.</summary>
public partial class DebugWindow : Window
{
    private readonly App _app;

    public DebugWindow(App app)
    {
        InitializeComponent();
        _app = app;
        Title = L10n.T("debug.title");
        Width = 620;
        Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        Background = (Brush)FindResource("Window.Background");
        TitleLabel.Text = L10n.T("debug.title");
        RefreshLabel.Text = L10n.T("debug.refresh");
        Loaded += (_, _) => Refresh();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };
    }

    private void OnRefresh(object sender, RoutedEventArgs e) => Refresh();

    private void Refresh()
    {
        RawTypes.Items.Clear();
        try
        {
            var dataObject = System.Windows.Clipboard.GetDataObject();
            if (dataObject is null)
            {
                ChangeCountText.Text = L10n.T("debug.no_data");
                return;
            }

            ChangeCountText.Text = L10n.Format("debug.change_count",
                ClipboardSequenceNumber());

            var formats = dataObject.GetFormats();
            for (var i = 0; i < formats.Length; i++)
            {
                RawTypes.Items.Add($"item[{i}] · {formats[i]}");
            }

            var decoded = ClipboardDecoder.Decode();
            var summary = decoded switch
            {
                null => L10n.T("debug.none"),
                _ when decoded.IsImage => $"image · {decoded.Content.ImageName ?? "-"} · {decoded.Content.OriginalByteCount / 1024} KB",
                _ when decoded.IsFileCollection => "fileURLs · " + string.Join(", ", decoded.Content.FilePaths ?? Array.Empty<string>()),
                _ => "text · " + PreviewText(decoded.TextValue ?? string.Empty),
            };
            DecodedText.Text = L10n.Format("debug.decoded", summary);
            PreviewBox.Text = decoded?.TextValue ?? string.Empty;
        }
        catch (Exception exception)
        {
            ChangeCountText.Text = "error: " + exception.Message;
        }
    }

    private static string PreviewText(string text) =>
        text.Length > 200 ? text[..200] + "…" : text;

    private static int ClipboardSequenceNumber()
    {
        try
        {
            return unchecked((int)SkyPaste.Interop.NativeMethods.GetClipboardSequenceNumber());
        }
        catch (Exception)
        {
            return 0;
        }
    }
}
