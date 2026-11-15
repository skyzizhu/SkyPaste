using System.IO;
using System.Threading;
using System.Windows;
using SkyPaste.Core.Data;
using SkyPaste.Core.Localization;
using SkyPaste.Core.Services;
using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Composition root: single instance guard, settings, store, clipboard monitor,
/// hotkey, theme, tray, LAN sync, and the window coordinator.
/// </summary>
public partial class App : Application
{
    private const string SingleInstanceMutexName = "Local\\SkyPasteSingleInstance";

    public AppSettingsService Settings { get; private set; } = null!;
    public ClipboardStore Store { get; private set; } = null!;
    public StatisticsDatabase Statistics { get; private set; } = null!;
    public ClipboardMonitorService Monitor { get; private set; } = null!;
    public GlobalHotKeyService HotKeys { get; private set; } = null!;
    public ThemeService Theme { get; private set; } = null!;
    public ToastService Toast { get; private set; } = null!;
    public LanSyncService LanSync { get; private set; } = null!;
    public AppCoordinator Coordinator { get; private set; } = null!;
    public TrayIconService TrayIcon { get; private set; } = null!;

    private Mutex? _singleInstanceMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var isNewInstance);
        if (!isNewInstance)
        {
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
        };

        Settings = new AppSettingsService();
        L10n.SetLanguage(Settings.LanguageCode);
        Settings.LanguageSettingsChanged += () => L10n.SetLanguage(Settings.LanguageCode);

        var database = new ClipboardDatabase(ClipboardDatabase.DefaultPath);
        Statistics = new StatisticsDatabase(StatisticsDatabase.DefaultPath);
        Store = new ClipboardStore(database, Statistics, Settings)
        {
            // Swap full images for <=240px thumbnails in memory.
            MemoryOptimizer = ImageOptimizerService.MemoryOptimize,
        };

        Theme = new ThemeService(Settings);
        Toast = new ToastService();
        Monitor = new ClipboardMonitorService(Settings);
        HotKeys = new GlobalHotKeyService(Settings);
        LanSync = new LanSyncService(Settings, Store);
        Coordinator = new AppCoordinator(this);
        TrayIcon = new TrayIconService(this);

        Theme.ApplyCurrentSetting();

        Monitor.ClipboardCaptured += OnClipboardCaptured;
        Store.OnLocalItemAdded += OnLocalItemAddedForSync;
        LanSync.ReceivedFromDevice += device =>
            Toast.Show(L10n.Format("sync.received_from", device));

        HotKeys.Pressed += Coordinator.TogglePanel;
        HotKeys.Initialize();
        HotKeys.RegistrationChanged += () =>
        {
            if (!HotKeys.IsRegistered)
            {
                Toast.Show(L10n.T("hotkey.register_failed"));
            }
        };
        Monitor.Start();
        LanSync.ApplyCurrentSetting();
        Settings.LanSyncSettingsChanged += () => LanSync.ApplyCurrentSetting();

        ApplyLaunchAtLogin();
        Settings.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppSettingsService.LaunchAtLogin))
            {
                ApplyLaunchAtLogin();
            }
        };

        DragOutService.CleanupTempDirectory();
        TrayIcon.Initialize();

        Coordinator.PreloadMainWindow();

        // CI smoke test hook (mirrors the macOS --uitesting flag): show the panel
        // immediately so headless environments can screenshot a real window.
        if (e.Args.Contains("--uitesting", StringComparer.OrdinalIgnoreCase))
        {
            Coordinator.ShowPanel();
        }
    }

    private void ApplyLaunchAtLogin() => LaunchAtLoginService.Apply(Settings.LaunchAtLogin);

    private void OnClipboardCaptured(Core.Models.ClipboardItem item) => Store.Add(item);

    private void OnLocalItemAddedForSync(Core.Models.ClipboardItem item)
    {
        if (!Settings.LanSyncEnabled || !Settings.LanSyncUploadEnabled)
        {
            return;
        }
        // Local text is pushed lazily: peers pull from us on their own schedule,
        // so nothing to send here. Keeping the hook documents the upload path.
    }

    protected override void OnExit(ExitEventArgs e)
    {
        TrayIcon?.Dispose();
        Monitor?.Dispose();
        HotKeys?.Dispose();
        LanSync?.Dispose();
        Theme?.Dispose();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }

    public void Quit()
    {
        Shutdown();
    }
}
