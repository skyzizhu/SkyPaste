using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using SkyPaste.Views.Controls;

namespace SkyPaste;

/// <summary>
/// Main panel window (mac: 700x620 floating NSPanel, centered, topmost,
/// Esc closes, Enter pastes, Ctrl+1..9 quick copy, stays visible on deactivate).
/// </summary>
public partial class MainWindow : Window
{
    private readonly App _app;
    private readonly ClipboardListPanel _panel;

    public MainWindow(App app)
    {
        InitializeComponent();
        _app = app;
        Title = "SkyPaste";
        Width = 720;
        Height = 640;
        MinWidth = 660;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.CanResize;
        Background = (System.Windows.Media.Brush)FindResource("Window.Background");

        _panel = new ClipboardListPanel(app, popoverMode: false);
        PanelHost.Content = _panel;
        _panel.CloseRequested += ClosePanel;
    }

    private void ClosePanel() => Hide();

    public void ShowPanel()
    {
        _app.Coordinator.CaptureForeground();
        _panel.RefreshLocalization();
        Show();
        Activate();
        Focus();
        _panel.Focus();
        _panel.OnStoreChanged();
    }

    public void OnStoreChanged() => _panel.OnStoreChanged();

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        if (_panel.HandleKeyDown(e.Key, Keyboard.Modifiers))
        {
            e.Handled = true;
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // The panel hides rather than closing (orderOut semantics).
        if (System.Windows.Application.Current is not null
            && !System.Windows.Application.Current.Dispatcher.HasShutdownStarted)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnClosing(e);
    }
}
