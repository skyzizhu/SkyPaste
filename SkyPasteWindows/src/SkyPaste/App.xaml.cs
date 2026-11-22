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
            UiLog("EXCEPTION " + args.Exception);
            try
            {
                var logDir = System.IO.Path.Combine(
                    AppSettingsService.DefaultDirectory, "logs");
                System.IO.Directory.CreateDirectory(logDir);
                var file = System.IO.Path.Combine(
                    logDir, $"ui-{DateTime.Now:yyyyMMdd}.log");
                System.IO.File.AppendAllText(file,
                    $"[{DateTime.Now:HH:mm:ss}] {args.Exception}\n\n");
            }
            catch
            {
                // Logging must never throw.
            }
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

        // CI smoke test hook: --uitesting[:main|settings|statistics] shows the
        // corresponding window so headless environments can screenshot it.
        var uitesting = e.Args.FirstOrDefault(a =>
            a.StartsWith("--uitesting", StringComparison.OrdinalIgnoreCase));
        if (uitesting is not null)
        {
            var scenario = uitesting.Contains(':')
                ? uitesting.Split(':', 2)[1].ToLowerInvariant()
                : "main";
            System.Windows.Window? target;
            switch (scenario)
            {
                case "settings":
                    Coordinator.ShowSettings();
                    target = Coordinator.SettingsWindowView;
                    break;
                case "statistics":
                    Coordinator.ShowStatistics();
                    target = Coordinator.StatisticsWindowView;
                    break;
                default:
                    Coordinator.ShowPanel();
                    target = Coordinator.MainWindowView;
                    break;
            }

            var smokeTimer = new System.Windows.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(6),
            };
            smokeTimer.Tick += (_, _) =>
            {
                smokeTimer.Stop();
                if (target is not null)
                {
                    Coordinator.CaptureWindowScreenshot(
                        target,
                        System.IO.Path.Combine(AppContext.BaseDirectory, $"smoke-{scenario}.png"));
                }
            };
            smokeTimer.Start();
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

    /// <summary>Diagnostics sink for the exception handler and window lifecycle notes.</summary>
    public static void UiLog(string line)
    {
        try
        {
            var logDir = System.IO.Path.Combine(
                AppSettingsService.DefaultDirectory, "logs");
            System.IO.Directory.CreateDirectory(logDir);
            var file = System.IO.Path.Combine(
                logDir, $"ui-{DateTime.Now:yyyyMMdd}.log");
            System.IO.File.AppendAllText(file,
                $"[{DateTime.Now:HH:mm:ss}] {line}\n\n");
        }
        catch
        {
            // Logging must never throw.
        }
    }
}
