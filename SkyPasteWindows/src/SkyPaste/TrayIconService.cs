using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Threading;
using SkyPaste.Core.Localization;
using Forms = System.Windows.Forms;

namespace SkyPaste.Services;

/// <summary>
/// The Windows tray icon (status bar item equivalent): click opens the main
/// panel, context menu offers panel / statistics / preferences / debug / quit.
/// </summary>
public sealed class TrayIconService : IDisposable
{
    private readonly App _app;
    private Forms.NotifyIcon? _notifyIcon;

    public TrayIconService(App app)
    {
        _app = app;
    }

    public void Initialize()
    {
        _notifyIcon = new Forms.NotifyIcon
        {
            Text = "SkyPaste",
            Visible = true,
        };
        _notifyIcon.Icon = ExtractAppIcon();
        _notifyIcon.Click += (_, args) =>
        {
            if (args is Forms.MouseEventArgs mouse && mouse.Button == Forms.MouseButtons.Left)
            {
                _app.Coordinator.ToggleTrayPopover();
            }
        };

        RebuildMenu();
        L10n.LanguageChanged += RebuildMenu;
        _app.Theme.ThemeChanged += RebuildMenu;
    }

    private void RebuildMenu()
    {
        if (_notifyIcon is null)
        {
            return;
        }
        var dark = _app.Theme.IsDarkMode;
        var foreground = dark ? Color.FromArgb(242, 242, 244) : Color.FromArgb(20, 20, 20);
        var danger = dark ? Color.FromArgb(255, 125, 115) : Color.FromArgb(176, 34, 32);
        var menuFont = new Font("Segoe UI", 10);
        var menu = new Forms.ContextMenuStrip
        {
            Font = menuFont,
            ForeColor = foreground,
            ImageScalingSize = new Size(20, 20),
            Padding = new Forms.Padding(4, 5, 4, 5),
            Renderer = new TrayMenuRenderer(dark),
        };
        menu.Disposed += (_, _) => menuFont.Dispose();
        AddMenuItem(menu, "menu.open_panel", "\uE8A9", foreground, _app.Coordinator.ShowPanel);
        menu.Items.Add(new Forms.ToolStripSeparator());
        AddMenuItem(menu, "stats.title", "\uE9D2", foreground, _app.Coordinator.ShowStatistics);
        AddMenuItem(menu, "menu.preferences", "\uE713", foreground, _app.Coordinator.ShowSettings);
        AddMenuItem(menu, "menu.debug", "\uEBE8", foreground, _app.Coordinator.ShowDebug);
        menu.Items.Add(new Forms.ToolStripSeparator());
        AddMenuItem(menu, "menu.quit", "\uE7E8", danger, _app.Quit);
        var previous = _notifyIcon.ContextMenuStrip;
        _notifyIcon.ContextMenuStrip = menu;
        previous?.Dispose();
    }

    private void AddMenuItem(Forms.ContextMenuStrip menu, string key, string glyph, Color color, Action action)
    {
        var image = new Bitmap(menu.ImageScalingSize.Width, menu.ImageScalingSize.Height);
        using (var graphics = Graphics.FromImage(image))
        using (var font = new Font("Segoe MDL2 Assets", 15, GraphicsUnit.Pixel))
        using (var brush = new SolidBrush(color))
        using (var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
        {
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            graphics.DrawString(glyph, font, brush, new RectangleF(0, 0, image.Width, image.Height), format);
        }

        var item = new Forms.ToolStripMenuItem(L10n.T(key), image)
        {
            Name = key,
            ForeColor = color,
            Padding = new Forms.Padding(0, 5, 12, 5),
        };
        item.Disposed += (_, _) => image.Dispose();
        item.Click += (_, _) => _app.Dispatcher.InvokeAsync(() =>
        {
            _app.Coordinator.CloseTrayPopover();
            action();
        }, DispatcherPriority.Background);
        menu.Items.Add(item);
    }

    private sealed class TrayMenuRenderer(bool dark) : Forms.ToolStripProfessionalRenderer
    {
        private readonly Color _surface = dark ? Color.FromArgb(32, 39, 53) : Color.White;
        private readonly Color _border = dark ? Color.FromArgb(58, 70, 90) : Color.FromArgb(220, 229, 241);
        private readonly Color _hover = dark ? Color.FromArgb(48, 61, 82) : Color.FromArgb(234, 241, 251);

        protected override void OnRenderToolStripBackground(Forms.ToolStripRenderEventArgs e)
        {
            using var brush = new SolidBrush(_surface);
            e.Graphics.FillRectangle(brush, e.AffectedBounds);
        }

        protected override void OnRenderImageMargin(Forms.ToolStripRenderEventArgs e)
        {
            using var brush = new SolidBrush(_surface);
            e.Graphics.FillRectangle(brush, e.AffectedBounds);
        }

        protected override void OnRenderToolStripBorder(Forms.ToolStripRenderEventArgs e)
        {
            var bounds = e.ToolStrip.ClientRectangle;
            using var pen = new Pen(_border);
            e.Graphics.DrawRectangle(pen, bounds.X, bounds.Y, bounds.Width - 1, bounds.Height - 1);
        }

        protected override void OnRenderMenuItemBackground(Forms.ToolStripItemRenderEventArgs e)
        {
            if (e.Item.Selected)
            {
                var surface = new Rectangle(Point.Empty, e.Item.Size);
                surface.Inflate(-2, -1);
                using var brush = new SolidBrush(_hover);
                e.Graphics.FillRectangle(brush, surface);
            }
        }

        protected override void OnRenderSeparator(Forms.ToolStripSeparatorRenderEventArgs e)
        {
            using var pen = new Pen(_border);
            var y = e.Item.Height / 2;
            e.Graphics.DrawLine(pen, 9, y, e.Item.Width - 9, y);
        }
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
        L10n.LanguageChanged -= RebuildMenu;
        _app.Theme.ThemeChanged -= RebuildMenu;
        if (_notifyIcon is not null)
        {
            var menu = _notifyIcon.ContextMenuStrip;
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _notifyIcon = null;
            menu?.Dispose();
        }
    }
}
