using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using SkyPaste.Views.Controls;

namespace SkyPaste;

/// <summary>
/// Tray popover (mac: 396x520 NSPopover, closes on outside click / deactivation,
/// list shows up to 80 items, single click copies only).
/// </summary>
public partial class TrayPopoverWindow : Window
{
    private readonly App _app;
    private readonly ClipboardListPanel _panel;

    public TrayPopoverWindow(App app)
    {
        InitializeComponent();
        _app = app;
        Title = "SkyPaste";
        Width = 400;
        Height = 540;
        MinWidth = 360;
        MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.CanResize;
        Background = (System.Windows.Media.Brush)FindResource("Window.Background");

        _panel = new ClipboardListPanel(app, popoverMode: true);
        PanelHost.Content = _panel;
        _panel.CloseRequested += () => Close();

        Deactivated += (_, _) => Close();
        Closing += OnClosingReal;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        // Anchor near the tray area (bottom-right of the primary work area).
        var workArea = SystemParameters.WorkArea;
        Left = workArea.Right - Width - 12;
        Top = workArea.Bottom - Height - 8;
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

    private void OnClosingReal(object? sender, CancelEventArgs e)
    {
        // Allow real close for this window (popover is recreated each time).
    }
}
