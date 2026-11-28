using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using SkyPaste.Core.Localization;
using SkyPaste.Services;

namespace SkyPaste;

/// <summary>
/// Preferences (mac SkySettingsView): general / hotkey / sync &amp; privacy /
/// library / about, one column, bound to AppSettingsService.
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly App _app;
    private bool _loading = true;
    private bool _draggingHistoryLimit;

    public SettingsWindow(App app)
    {
        _app = app;
        InitializeComponent();
        Width = 860;
        Height = 660;
        MinWidth = 760;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = true;
        ShowActivated = true;
        SetResourceReference(BackgroundProperty, "Window.Background");

        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };

        BuildLanguageOptions();
        BuildKeyOptions();
        ApplyLocalization();
        LoadSettings();
        UpdateQrPanel();
        BuildRecentAppChips();

        _app.LanSync.StatusChanged += UpdateLanSyncStatus;
        _app.LanSync.IpChanged += OnLanIpChanged;
        _app.HotKeys.RegistrationChanged += UpdateHotKeyDisplay;
        L10n.LanguageChanged += ApplyLocalization;
        Closed += (_, _) =>
        {
            _app.LanSync.StatusChanged -= UpdateLanSyncStatus;
            _app.LanSync.IpChanged -= OnLanIpChanged;
            _app.HotKeys.RegistrationChanged -= UpdateHotKeyDisplay;
            L10n.LanguageChanged -= ApplyLocalization;
        };

    }

    private void ApplyLocalization()
    {
        Title = L10n.T("menu.preferences");
        SectionGeneral.Header = L10n.T("settings.general");
        SectionHotkey.Header = L10n.T("settings.hotkey");
        SectionSync.Header = L10n.T("settings.sync");
        SectionLibrary.Header = L10n.T("settings.library");
        SectionAbout.Header = L10n.T("settings.support");

        AppearanceLabel.Text = L10n.T("settings.appearance");
        LanguageLabel.Text = L10n.T("settings.language");
        LaunchAtLoginLabel.Text = L10n.T("settings.launch_at_login");
        LaunchAtLoginHint.Text = L10n.T("settings.launch_at_login_hint");
        AutoPasteLabel.Text = L10n.T("settings.auto_paste");
        AutoPasteHint.Text = L10n.T("settings.auto_paste_hint");
        PanelPositionLabel.Text = L10n.T("settings.panel_position");

        KeyLabel.Text = L10n.T("settings.key");
        CtrlToggleLabel.Text = L10n.T("settings.ctrl");
        ShiftToggleLabel.Text = L10n.T("settings.shift");
        AltToggleLabel.Text = L10n.T("settings.alt");
        WinToggleLabel.Text = L10n.T("settings.win");

        LanSyncLabel.Text = L10n.T("settings.lan_sync");
        WindowsClipboardSettingsButton.Content = L10n.T("settings.windows_clipboard");
        LanSyncHint.Text = L10n.T("settings.lan_sync_hint");
        LanSyncUploadLabel.Text = L10n.T("settings.lan_sync_upload");
        LanSyncReceiveLabel.Text = L10n.T("settings.lan_sync_receive");
        DeviceNameLabel.Text = L10n.T("settings.lan_sync_device_name");
        PortLabel.Text = L10n.T("settings.lan_sync_port");
        TokenLabel.Text = L10n.T("settings.lan_sync_token");
        TokenHint.Text = L10n.T("settings.lan_sync_token_hint");
        PrivacyFilterLabel.Text = L10n.T("settings.privacy_filter");
        PrivacyFilterHint.Text = L10n.T("settings.privacy_filter_hint");

        HistoryHint.Text = L10n.T("settings.history_hint");
        IgnoreAppsLabel.Text = L10n.T("settings.ignore_apps");
        IgnoreAppsHint.Text = L10n.T("settings.ignore_apps_hint");
        IgnoreAppsExample.Text = L10n.T("settings.ignore_apps_example");
        RecentLabel.Text = L10n.T("settings.ignore_apps_suggestions");

        AboutSubtitle.Text = L10n.T("about.subtitle");
        OpenLicenseLabel.Text = L10n.T("about.open_license");
        WenPaiTitle.Text = L10n.T("wenpai.title");
        WenPaiSubtitle.Text = L10n.T("wenpai.subtitle");
        WenPaiButton.Content = L10n.T("wenpai.open");

        SetComboItemsText(AppearanceMode,
            "appearance.system", "appearance.light", "appearance.dark");
        SetComboItemsText(LanguageMode,
            "language.system", "language.en", "language.zh-Hans", "language.zh-Hant", "language.ja", "language.ko", "language.fr");
        SetComboItemsText(PanelPosition,
            "panel_position.center", "panel_position.cursor", "panel_position.remember");

        var version = typeof(App).Assembly.GetName().Version;
        VersionText.Text = L10n.Format("settings.version_format",
            version?.ToString() ?? "0.1.0", "Windows 10/11");
        MaxRecordsValue.Text = L10n.Format("settings.max_records", _app.Settings.HistoryLimit);
        UpdateHotKeyDisplay();
        UpdateLanSyncStatus();
    }

    private static void SetComboItemsText(System.Windows.Controls.ComboBox combo, params string[] keys)
    {
        for (var i = 0; i < keys.Length && i < combo.Items.Count; i++)
        {
            if (combo.Items[i] is System.Windows.Controls.ComboBoxItem item)
            {
                item.Content = L10n.T(keys[i]);
            }
        }
    }

    private void LoadSettings()
    {
        var settings = _app.Settings;
        AppearanceMode.SelectedIndex = settings.AppearanceMode switch
        {
            "light" => 1,
            "dark" => 2,
            _ => 0,
        };
        LanguageMode.SelectedIndex = settings.LanguageCode switch
        {
            "en" => 1,
            "zh-Hans" => 2,
            "zh-Hant" => 3,
            "ja" => 4,
            "ko" => 5,
            "fr" => 6,
            _ => 0,
        };
        PanelPosition.SelectedIndex = settings.PanelPosition switch
        {
            "cursor" => 1,
            "remember" => 2,
            _ => 0,
        };
        LaunchAtLoginToggle.IsChecked = settings.LaunchAtLogin;
        AutoPasteToggle.IsChecked = settings.AutoPasteEnabled;
        KeyMode.SelectedItem = settings.HotKeyKey;
        CtrlToggle.IsChecked = settings.HotKeyCtrl;
        ShiftToggle.IsChecked = settings.HotKeyShift;
        AltToggle.IsChecked = settings.HotKeyAlt;
        WinToggle.IsChecked = settings.HotKeyWin;
        LanSyncToggle.IsChecked = settings.LanSyncEnabled;
        LanSyncUploadToggle.IsChecked = settings.LanSyncUploadEnabled;
        LanSyncReceiveToggle.IsChecked = settings.LanSyncReceiveEnabled;
        DeviceNameBox.Text = settings.DeviceName;
        PortBox.Text = settings.LanSyncPort.ToString();
        TokenBox.Text = settings.LanSyncToken;
        PrivacyFilterToggle.IsChecked = settings.PrivacyFilteringEnabled;
        HistoryLimitSlider.Value = settings.HistoryLimit;
        MaxRecordsValue.Text = L10n.Format("settings.max_records", settings.HistoryLimit);
        IgnoreAppsBox.Text = settings.IgnoredAppsInput;
        UpdateHotKeyDisplay();
        UpdateLanSyncStatus();
        _loading = false;
    }

    private void BuildLanguageOptions()
    {
        LanguageMode.Items.Add(new ComboBoxItem { Content = L10n.T("language.system") });
        LanguageMode.Items.Add(new ComboBoxItem { Content = L10n.T("language.en") });
        LanguageMode.Items.Add(new ComboBoxItem { Content = L10n.T("language.zh-Hans") });
        LanguageMode.Items.Add(new ComboBoxItem { Content = L10n.T("language.zh-Hant") });
        LanguageMode.Items.Add(new ComboBoxItem { Content = L10n.T("language.ja") });
        LanguageMode.Items.Add(new ComboBoxItem { Content = L10n.T("language.ko") });
        LanguageMode.Items.Add(new ComboBoxItem { Content = L10n.T("language.fr") });
    }

    private void BuildKeyOptions()
    {
        for (var c = 'A'; c <= 'Z'; c++)
        {
            KeyMode.Items.Add(c.ToString());
        }
    }

    private void BuildRecentAppChips()
    {
        RecentHost.Children.Clear();
        var ignored = _app.Settings.IgnoredApps;
        var recent = _app.Store.Items
            .Select(i => i.SourceApp?.Name)
            .Where(name => name is not null && !ignored.Contains(name!.ToLowerInvariant()))
            .Distinct()
            .Take(8)
            .ToList();
        foreach (var name in recent)
        {
            var chip = new Button
            {
                Style = (Style)FindResource("CapsuleButton"),
                Content = name,
                Margin = new Thickness(0, 0, 6, 6),
            };
            chip.Click += (_, _) =>
            {
                IgnoreAppsBox.Text = string.IsNullOrWhiteSpace(IgnoreAppsBox.Text)
                    ? name
                    : IgnoreAppsBox.Text.TrimEnd() + ", " + name;
                SaveIgnoreApps();
            };
            RecentHost.Children.Add(chip);
        }
    }

    // ---- handlers ---------------------------------------------------------------------------

    private void OnAppearanceChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        _app.Settings.AppearanceMode = AppearanceMode.SelectedIndex switch
        {
            1 => "light",
            2 => "dark",
            _ => "system",
        };
    }

    private void OnPanelPositionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        _app.Settings.PanelPosition = PanelPosition.SelectedIndex switch
        {
            1 => "cursor",
            2 => "remember",
            _ => "center",
        };
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        _app.Settings.LanguageCode = LanguageMode.SelectedIndex switch
        {
            1 => "en",
            2 => "zh-Hans",
            3 => "zh-Hant",
            4 => "ja",
            5 => "ko",
            6 => "fr",
            _ => "system",
        };
    }

    private async void OnOpenWindowsClipboardSettings(object sender, RoutedEventArgs e)
    {
        await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:clipboard"));
    }

    private void OnOpenWenPai(object sender, RoutedEventArgs e) =>
        _app.Coordinator.OpenInBrowser(new Uri("https://wol.yourtools.xyz/"));

    private void OnToggleChanged(object sender, RoutedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        var settings = _app.Settings;
        if (sender == LaunchAtLoginToggle)
        {
            settings.LaunchAtLogin = LaunchAtLoginToggle.IsChecked == true;
        }
        else if (sender == AutoPasteToggle)
        {
            settings.AutoPasteEnabled = AutoPasteToggle.IsChecked == true;
        }
        else if (sender == LanSyncToggle)
        {
            if (LanSyncToggle.IsChecked == true && !_app.Settings.LanSyncHintShown)
            {
                // Show before applying so the firewall prompt appears right after the user reads it.
                MessageBox.Show(this, L10n.T("settings.lan_sync_firewall_hint"),
                    L10n.T("settings.lan_sync"), MessageBoxButton.OK, MessageBoxImage.Information);
                _app.Settings.LanSyncHintShown = true;
            }
            settings.LanSyncEnabled = LanSyncToggle.IsChecked == true;
            UpdateQrPanel();
        }
        else if (sender == LanSyncUploadToggle)
        {
            settings.LanSyncUploadEnabled = LanSyncUploadToggle.IsChecked == true;
        }
        else if (sender == LanSyncReceiveToggle)
        {
            settings.LanSyncReceiveEnabled = LanSyncReceiveToggle.IsChecked == true;
        }
        else if (sender == PrivacyFilterToggle)
        {
            settings.PrivacyFilteringEnabled = PrivacyFilterToggle.IsChecked == true;
        }
        else if (sender == CtrlToggle || sender == ShiftToggle || sender == AltToggle || sender == WinToggle)
        {
            settings.HotKeyCtrl = CtrlToggle.IsChecked == true;
            settings.HotKeyShift = ShiftToggle.IsChecked == true;
            settings.HotKeyAlt = AltToggle.IsChecked == true;
            settings.HotKeyWin = WinToggle.IsChecked == true;
            UpdateHotKeyDisplay();
        }
    }

    private void OnKeyChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || KeyMode.SelectedItem is not string key)
        {
            return;
        }
        _app.Settings.HotKeyKey = key;
        UpdateHotKeyDisplay();
    }

    private void UpdateHotKeyDisplay()
    {
        HotKeyDisplay.Text = L10n.Format("settings.current", _app.Settings.HotKeyDisplayText);
        HotKeyWarning.Text = !_app.Settings.HasHotKeyModifier
            ? L10n.T("hotkey.requires_modifier")
            : _app.HotKeys.IsRegistered ? string.Empty : L10n.T("hotkey.register_failed");
    }

    private void OnDeviceNameFocusLost(object sender, KeyboardFocusChangedEventArgs e) => CommitDeviceName();

    private void OnDeviceNameKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            CommitDeviceName();
            e.Handled = true;
        }
    }

    private void CommitDeviceName()
    {
        if (_loading)
        {
            return;
        }
        _app.Settings.DeviceName = DeviceNameBox.Text;
        DeviceNameBox.Text = _app.Settings.DeviceName;
    }

    private void OnPortFocusLost(object sender, KeyboardFocusChangedEventArgs e) => CommitPort();

    private void OnPortKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            CommitPort();
            e.Handled = true;
        }
    }

    private void CommitPort()
    {
        if (!_loading && int.TryParse(PortBox.Text, out var port) && port is >= 1024 and <= 65535
            && port != _app.Settings.LanSyncPort)
        {
            _app.Settings.LanSyncPort = port;
            UpdateQrPanel();
        }
        PortBox.Text = _app.Settings.LanSyncPort.ToString();
    }

    private void OnHistoryLimitChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (MaxRecordsValue is null || _app is null || _loading)
        {
            return;
        }
        // Snap to steps of 20 between 20 and 1000 (mac Stepper semantics).
        var snapped = Math.Max(20, (int)Math.Round(e.NewValue / 20.0) * 20);
        if (!_draggingHistoryLimit)
        {
            _app.Settings.HistoryLimit = snapped;
        }
        MaxRecordsValue.Text = L10n.Format("settings.max_records", snapped);
    }

    private void OnHistoryLimitDragStarted(object sender, System.Windows.Controls.Primitives.DragStartedEventArgs e) =>
        _draggingHistoryLimit = true;

    private void OnHistoryLimitDragCompleted(object sender, System.Windows.Controls.Primitives.DragCompletedEventArgs e)
    {
        _draggingHistoryLimit = false;
        if (e.Canceled)
        {
            HistoryLimitSlider.Value = _app.Settings.HistoryLimit;
            return;
        }
        _app.Settings.HistoryLimit = (int)HistoryLimitSlider.Value;
    }

    private void SaveIgnoreApps()
    {
        _app.Settings.IgnoredAppsInput = IgnoreAppsBox.Text;
        BuildRecentAppChips();
    }

    private void OnIgnoreAppsChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }
        SaveIgnoreApps();
    }

    private void UpdateQrPanel()
    {
        var enabled = _app.Settings.LanSyncEnabled;
        QrPanel.Visibility = enabled ? System.Windows.Visibility.Visible : System.Windows.Visibility.Collapsed;
        if (!enabled)
        {
            return;
        }
        QrLabel.Text = L10n.T("settings.lan_sync_qr");
        QrHint.Text = L10n.T("settings.lan_sync_qr_hint");
        var url = _app.LanSync.PairingUrl;
        QrUrlText.Text = url;
        QrMetaText.Text = "IP: " + (Core.Services.LanSyncService.LocalIPv4 ?? "-")
            + " · " + L10n.Format("settings.lan_sync_qr_generated", DateTime.Now.ToString("HH:mm:ss"));
        try
        {
            using var generator = new QRCoder.QRCodeGenerator();
            var data = generator.CreateQrCode(url, QRCoder.QRCodeGenerator.ECCLevel.M);
            var png = new QRCoder.PngByteQRCode(data).GetGraphic(10);
            var image = System.Windows.Media.Imaging.BitmapFrame.Create(
                new System.IO.MemoryStream(png), System.Windows.Media.Imaging.BitmapCreateOptions.None,
                System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
            QrImage.Source = image;
        }
        catch (Exception)
        {
            QrImage.Source = null;
        }
    }

    private void OnLanIpChanged(string ip)
    {
        Dispatcher.Invoke(() =>
        {
            UpdateQrPanel();
            _app.Toast.Show(L10n.Format("settings.lan_sync_ip_changed_toast", ip));
        });
    }

    private void UpdateLanSyncStatus()
    {
        var status = _app.LanSync.Status switch
        {
            Core.Services.LanSyncStatus.Synced => L10n.T("settings.lan_sync_status_synced"),
            Core.Services.LanSyncStatus.Syncing => L10n.T("settings.lan_sync_status_syncing"),
            Core.Services.LanSyncStatus.Unavailable => L10n.T("settings.lan_sync_status_unavailable"),
            Core.Services.LanSyncStatus.Error => L10n.Format("settings.lan_sync_status_error", _app.LanSync.StatusError ?? ""),
            _ => L10n.T("settings.lan_sync_status_disabled"),
        };
        LanSyncStatus.Text = status;
    }

    private void OnOpenLicense(object sender, RoutedEventArgs e)
    {
        try
        {
            var license = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "LICENSE");
            if (System.IO.File.Exists(license))
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = license,
                    UseShellExecute = true,
                });
            }
        }
        catch (Exception)
        {
        }
    }
}
