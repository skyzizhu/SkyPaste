using System.Windows;
using System.Windows.Input;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Models;
using SkyPaste.Services;
using SkyPaste.Views.Controls;

namespace SkyPaste;

public partial class ImagePreviewWindow : Window
{
    public ImagePreviewWindow(App app, ClipboardItem item)
    {
        InitializeComponent();
        Title = L10n.T("preview.title");
        Width = 1000;
        Height = 700;
        MinWidth = 760;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Content = new ImagePreviewWorkspace(app, item);

        SourceInitialized += (_, _) => WindowEffectsService.EnableRoundedCorners(this);
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
                e.Handled = true;
            }
        };
    }
}
