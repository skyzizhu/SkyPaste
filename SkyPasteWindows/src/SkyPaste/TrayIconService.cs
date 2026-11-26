using System.Drawing;
using SkyPaste.Core.Localization;

namespace SkyPaste.Services;

/// <summary>
/// The Windows tray icon (status bar item equivalent): click opens the main
/// panel, context menu offers panel / statistics / preferences / debug / quit.
/// </summary>
public sealed class TrayIconService : IDisposable
{
    private readonly App _app;
    private System.Windows.Forms.NotifyIcon? _notifyIcon;

    public TrayIconService(App app)
    {
        _app = app;
    }

    public void Initialize()
    {
        _notifyIcon = new System.Windows.Forms.NotifyIcon
        {
            Text = "SkyPaste",
            Visible = true,
        };
        _notifyIcon.Icon = ExtractAppIcon();
        _notifyIcon.Click += (_, args) =>
        {
            if (args is System.Windows.Forms.MouseEventArgs mouse && mouse.Button == System.Windows.Forms.MouseButtons.Left)
            {
                _app.Coordinator.ToggleTrayPopover();
            }
        };

        RebuildMenu();
        SkyPaste.Core.Localization.L10n.LanguageChanged += RebuildMenu;
    }

    private void RebuildMenu()
    {
        if (_notifyIcon is null)
        {
            return;
        }
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add(L10n.T("menu.open_panel"), null, (_, _) => _app.Coordinator.ShowPanel());
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add(L10n.T("stats.title"), null, (_, _) => _app.Coordinator.ShowStatistics());
        menu.Items.Add(L10n.T("menu.preferences"), null, (_, _) => _app.Coordinator.ShowSettingsAfterMenu());
        menu.Items.Add(L10n.T("menu.debug"), null, (_, _) => _app.Coordinator.ShowDebug());
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add(L10n.T("menu.quit"), null, (_, _) => _app.Quit());
        _notifyIcon.ContextMenuStrip = menu;
    }

    private static Icon ExtractAppIcon()
    {
        try
        {
            var uri = new Uri("pack://application:,,,/SkyPaste;component/Assets/icon.ico", UriKind.Absolute);
            var stream = System.Windows.Application.GetResourceStream(uri)?.Stream;
            if (stream is not null)
            {
                return new Icon(stream);
            }
        }
        catch (Exception)
        {
        }
        return Icon.ExtractAssociatedIcon(Environment.ProcessPath ?? "app.exe") ?? SystemIcons.Application;
    }

    public void Dispose()
    {
        SkyPaste.Core.Localization.L10n.LanguageChanged -= RebuildMenu;
        if (_notifyIcon is not null)
        {
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _notifyIcon = null;
        }
    }
}
