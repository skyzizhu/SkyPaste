using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using SkyPaste.Core.Models;

namespace SkyPaste.Core.Services;

public enum AppAppearanceMode
{
    System,
    Light,
    Dark,
}

/// <summary>
/// Port of macOS AppSettings (UserDefaults settings.* keys) to a JSON file at
/// %APPDATA%\SkyPaste\settings.json. Change events mirror the macOS notification names.
/// </summary>
public sealed class AppSettingsService : INotifyPropertyChanged
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    private readonly object _saveLock = new();

    public static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SkyPaste");

    public string FilePath { get; }

    public AppSettingsService(string? directory = null)
    {
        var dir = directory ?? DefaultDirectory;
        Directory.CreateDirectory(dir);
        FilePath = Path.Combine(dir, "settings.json");
        Load();
    }

    // ---- stored properties ----------------------------------------------

    private int _historyLimit = 200;
    public int HistoryLimit
    {
        get => _historyLimit;
        set
        {
            var clamped = ClampHistoryLimit(value);
            if (Set(ref _historyLimit, clamped, nameof(HistoryLimit)))
            {
                HistoryLimitChanged?.Invoke();
                Save();
            }
        }
    }

    private string _hotKeyKey = "V";
    public string HotKeyKey
    {
        get => _hotKeyKey;
        set => SetAndSave(ref _hotKeyKey, NormalizeKey(value), nameof(HotKeyKey), HotKeySettingsChanged);
    }

    private bool _hotKeyCtrl = true;
    public bool HotKeyCtrl
    {
        get => _hotKeyCtrl;
        set => SetAndSave(ref _hotKeyCtrl, value, nameof(HotKeyCtrl), HotKeySettingsChanged);
    }

    private bool _hotKeyShift = true;
    public bool HotKeyShift
    {
        get => _hotKeyShift;
        set => SetAndSave(ref _hotKeyShift, value, nameof(HotKeyShift), HotKeySettingsChanged);
    }

    private bool _hotKeyAlt;
    public bool HotKeyAlt
    {
        get => _hotKeyAlt;
        set => SetAndSave(ref _hotKeyAlt, value, nameof(HotKeyAlt), HotKeySettingsChanged);
    }

    private bool _hotKeyWin;
    public bool HotKeyWin
    {
        get => _hotKeyWin;
        set => SetAndSave(ref _hotKeyWin, value, nameof(HotKeyWin), HotKeySettingsChanged);
    }

    private string _ignoredAppsInput = string.Empty;
    public string IgnoredAppsInput
    {
        get => _ignoredAppsInput;
        set => SetAndSave(ref _ignoredAppsInput, value, nameof(IgnoredAppsInput));
    }

    private bool _launchAtLogin = true;
    public bool LaunchAtLogin
    {
        get => _launchAtLogin;
        set => SetAndSave(ref _launchAtLogin, value, nameof(LaunchAtLogin));
    }

    private bool _autoPasteEnabled = true;
    public bool AutoPasteEnabled
    {
        get => _autoPasteEnabled;
        set => SetAndSave(ref _autoPasteEnabled, value, nameof(AutoPasteEnabled));
    }

    private bool _privacyFilteringEnabled;
    public bool PrivacyFilteringEnabled
    {
        get => _privacyFilteringEnabled;
        set => SetAndSave(ref _privacyFilteringEnabled, value, nameof(PrivacyFilteringEnabled));
    }

    private bool _lanSyncEnabled;
    public bool LanSyncEnabled
    {
        get => _lanSyncEnabled;
        set => SetAndSave(ref _lanSyncEnabled, value, nameof(LanSyncEnabled), LanSyncSettingsChanged);
    }

    private bool _lanSyncUploadEnabled = true;
    public bool LanSyncUploadEnabled
    {
        get => _lanSyncUploadEnabled;
        set => SetAndSave(ref _lanSyncUploadEnabled, value, nameof(LanSyncUploadEnabled), LanSyncSettingsChanged);
    }

    private bool _lanSyncReceiveEnabled = true;
    public bool LanSyncReceiveEnabled
    {
        get => _lanSyncReceiveEnabled;
        set => SetAndSave(ref _lanSyncReceiveEnabled, value, nameof(LanSyncReceiveEnabled), LanSyncSettingsChanged);
    }

    private int _lanSyncPort = 26177;
    public int LanSyncPort
    {
        get => _lanSyncPort;
        set => SetAndSave(ref _lanSyncPort, Math.Clamp(value, 1024, 65535), nameof(LanSyncPort), LanSyncSettingsChanged);
    }

    private string _lanSyncToken = string.Empty;
    public string LanSyncToken
    {
        get
        {
            if (string.IsNullOrEmpty(_lanSyncToken))
            {
                _lanSyncToken = Guid.NewGuid().ToString("N")[..12].ToUpperInvariant();
                Save();
            }
            return _lanSyncToken;
        }
        set => SetAndSave(ref _lanSyncToken, value, nameof(LanSyncToken));
    }

    private string _deviceName = Environment.MachineName;
    public string DeviceName
    {
        get => string.IsNullOrWhiteSpace(_deviceName) ? Environment.MachineName : _deviceName;
        set => SetAndSave(ref _deviceName, string.IsNullOrWhiteSpace(value) ? Environment.MachineName : value.Trim(), nameof(DeviceName), LanSyncSettingsChanged);
    }

    private string _languageCode = "system";
    public string LanguageCode
    {
        get => _languageCode;
        set => SetAndSave(ref _languageCode, NormalizeLanguage(value), nameof(LanguageCode), LanguageSettingsChanged);
    }

    private string _panelPosition = "center";
    public string PanelPosition
    {
        get => _panelPosition;
        set => SetAndSave(ref _panelPosition, NormalizePanelPosition(value), nameof(PanelPosition));
    }

    private bool _lanSyncHintShown;
    public bool LanSyncHintShown
    {
        get => _lanSyncHintShown;
        set => SetAndSave(ref _lanSyncHintShown, value, nameof(LanSyncHintShown));
    }

    private string _appearanceMode = "system";
    public string AppearanceMode
    {
        get => _appearanceMode;
        set => SetAndSave(ref _appearanceMode, NormalizeAppearance(value), nameof(AppearanceMode), AppearanceSettingsChanged);
    }

    private List<string> _filterOrder = new();
    public IReadOnlyList<string> FilterOrder
    {
        get => _filterOrder;
        set
        {
            var normalized = ClipboardFilterExtensions
                .NormalizeReorderableOrder(value.Select(f => Enum.TryParse<ClipboardFilter>(f, out var parsed) ? parsed : ClipboardFilter.All))
                .Select(f => f.ToString())
                .ToList();
            if (Set(ref _filterOrder, normalized, nameof(FilterOrder)))
            {
                FilterOrderSettingsChanged?.Invoke();
                Save();
            }
        }
    }

    // ---- derived helpers --------------------------------------------------

    public static int ClampHistoryLimit(int value)
    {
        if (value <= 0)
        {
            return 200;
        }
        return Math.Clamp(value, 20, 1000);
    }

    private static string NormalizeKey(string value)
    {
        var c = (value ?? "V").Trim().ToUpperInvariant();
        return c.Length == 1 && c[0] is >= 'A' and <= 'Z' ? c : "V";
    }

    private static string NormalizeLanguage(string value) =>
        value is "en" or "zh-Hans" or "zh-Hant" or "ja" or "ko" or "fr" ? value : "system";

    private static string NormalizeAppearance(string value) =>
        value is "light" or "dark" ? value : "system";

    private static string NormalizePanelPosition(string value) =>
        value is "cursor" or "remember" ? value : "center";

    public AppAppearanceMode Appearance => AppearanceMode switch
    {
        "light" => AppAppearanceMode.Light,
        "dark" => AppAppearanceMode.Dark,
        _ => AppAppearanceMode.System,
    };

    /// <summary>Ignored apps parsed from comma/newline separated input, folded for matching.</summary>
    public HashSet<string> IgnoredApps =>
        IgnoredAppsInput
            .Split(['\n', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(s => s.Trim().ToLowerInvariant())
            .Where(s => s.Length > 0)
            .ToHashSet();

    public string HotKeyDisplayText
    {
        get
        {
            var parts = new List<string>();
            if (HotKeyCtrl)
            {
                parts.Add("Ctrl");
            }
            if (HotKeyShift)
            {
                parts.Add("Shift");
            }
            if (HotKeyAlt)
            {
                parts.Add("Alt");
            }
            if (HotKeyWin)
            {
                parts.Add("Win");
            }
            parts.Add(HotKeyKey);
            return string.Join("+", parts);
        }
    }

    // ---- events -----------------------------------------------------------

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? HotKeySettingsChanged;
    public event Action? LanguageSettingsChanged;
    public event Action? AppearanceSettingsChanged;
    public event Action? FilterOrderSettingsChanged;
    public event Action? LanSyncSettingsChanged;
    public event Action? HistoryLimitChanged;

    private bool Set<T>(ref T field, T value, string propertyName)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        return true;
    }

    private void SetAndSave<T>(ref T field, T value, string propertyName, Action? extraEvent = null)
    {
        if (!Set(ref field, value, propertyName))
        {
            return;
        }
        extraEvent?.Invoke();
        Save();
    }

    // ---- persistence ------------------------------------------------------

    private void Load()
    {
        try
        {
            if (!File.Exists(FilePath))
            {
                return;
            }
            using var stream = File.OpenRead(FilePath);
            var doc = JsonSerializer.Deserialize<SettingsDto>(stream, SerializerOptions);
            if (doc is null)
            {
                return;
            }
            _historyLimit = ClampHistoryLimit(doc.HistoryLimit);
            _hotKeyKey = NormalizeKey(doc.HotKeyKey);
            _hotKeyCtrl = doc.HotKeyCtrl;
            _hotKeyShift = doc.HotKeyShift;
            _hotKeyAlt = doc.HotKeyAlt;
            _hotKeyWin = doc.HotKeyWin;
            _ignoredAppsInput = doc.IgnoredAppsInput ?? string.Empty;
            _launchAtLogin = doc.LaunchAtLogin;
            _autoPasteEnabled = doc.AutoPasteEnabled;
            _privacyFilteringEnabled = doc.PrivacyFilteringEnabled;
            _lanSyncEnabled = doc.LanSyncEnabled;
            _lanSyncUploadEnabled = doc.LanSyncUploadEnabled;
            _lanSyncReceiveEnabled = doc.LanSyncReceiveEnabled;
            _lanSyncPort = Math.Clamp(doc.LanSyncPort, 1024, 65535);
            _lanSyncToken = doc.LanSyncToken ?? string.Empty;
            _deviceName = string.IsNullOrWhiteSpace(doc.DeviceName) ? Environment.MachineName : doc.DeviceName;
            _languageCode = NormalizeLanguage(doc.LanguageCode);
            _appearanceMode = NormalizeAppearance(doc.AppearanceMode);
            _panelPosition = NormalizePanelPosition(doc.PanelPosition);
            _lanSyncHintShown = doc.LanSyncHintShown;
            _filterOrder = (doc.FilterOrder ?? new List<string>()).ToList();
        }
        catch (Exception)
        {
            // Corrupt settings file: start with defaults rather than crashing.
        }
    }

    public void Save()
    {
        lock (_saveLock)
        {
            try
            {
                var dto = new SettingsDto
                {
                    HistoryLimit = _historyLimit,
                    HotKeyKey = _hotKeyKey,
                    HotKeyCtrl = _hotKeyCtrl,
                    HotKeyShift = _hotKeyShift,
                    HotKeyAlt = _hotKeyAlt,
                    HotKeyWin = _hotKeyWin,
                    IgnoredAppsInput = _ignoredAppsInput,
                    LaunchAtLogin = _launchAtLogin,
                    AutoPasteEnabled = _autoPasteEnabled,
                    PrivacyFilteringEnabled = _privacyFilteringEnabled,
                    LanSyncEnabled = _lanSyncEnabled,
                    LanSyncUploadEnabled = _lanSyncUploadEnabled,
                    LanSyncReceiveEnabled = _lanSyncReceiveEnabled,
                    LanSyncPort = _lanSyncPort,
                    LanSyncToken = _lanSyncToken,
                    DeviceName = _deviceName,
                    LanguageCode = _languageCode,
                    AppearanceMode = _appearanceMode,
                    PanelPosition = _panelPosition,
                    LanSyncHintShown = _lanSyncHintShown,
                    FilterOrder = _filterOrder,
                };
                using var stream = File.Create(FilePath);
                JsonSerializer.Serialize(stream, dto, SerializerOptions);
            }
            catch (IOException)
            {
                // Best-effort persistence; transient IO errors are ignored.
            }
        }
    }

    private sealed class SettingsDto
    {
        public int HistoryLimit { get; set; } = 200;
        public string HotKeyKey { get; set; } = "V";
        public bool HotKeyCtrl { get; set; } = true;
        public bool HotKeyShift { get; set; } = true;
        public bool HotKeyAlt { get; set; }
        public bool HotKeyWin { get; set; }
        public string? IgnoredAppsInput { get; set; }
        public bool LaunchAtLogin { get; set; } = true;
        public bool AutoPasteEnabled { get; set; } = true;
        public bool PrivacyFilteringEnabled { get; set; }
        public bool LanSyncEnabled { get; set; }
        public bool LanSyncUploadEnabled { get; set; } = true;
        public bool LanSyncReceiveEnabled { get; set; } = true;
        public int LanSyncPort { get; set; } = 26177;
        public string? LanSyncToken { get; set; }
        public string? DeviceName { get; set; }
        public string LanguageCode { get; set; } = "system";
        public string AppearanceMode { get; set; } = "system";
        public string PanelPosition { get; set; } = "center";
        public bool LanSyncHintShown { get; set; }
        public List<string>? FilterOrder { get; set; }
    }
}
