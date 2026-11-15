using Microsoft.Win32;
using SkyPaste.Core.Services;

namespace SkyPaste.Services;

/// <summary>
/// Port of the macOS appearance setting: Follow System / Light / Dark by
/// swapping merged resource dictionaries. System mode tracks the Windows registry.
/// </summary>
public sealed class ThemeService : IDisposable
{
    private const string LightDictionary = "Views/Styles/Theme.Light.xaml";
    private const string DarkDictionary = "Views/Styles/Theme.Dark.xaml";

    private readonly AppSettingsService _settings;

    public ThemeService(AppSettingsService settings)
    {
        _settings = settings;
        _settings.AppearanceSettingsChanged += ApplyCurrentSetting;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
    }

    public bool IsDarkMode { get; private set; }

    public void ApplyCurrentSetting()
    {
        var mode = _settings.Appearance;
        var dark = mode switch
        {
            AppAppearanceMode.Light => false,
            AppAppearanceMode.Dark => true,
            _ => IsSystemDarkMode(),
        };
        Apply(dark);
    }

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category == UserPreferenceCategory.General && _settings.Appearance == AppAppearanceMode.System)
        {
            Apply(IsSystemDarkMode());
        }
    }

    private void Apply(bool dark)
    {
        IsDarkMode = dark;
        var dictionaries = System.Windows.Application.Current?.Resources?.MergedDictionaries;
        if (dictionaries is null)
        {
            return;
        }
        for (var i = dictionaries.Count - 1; i >= 0; i--)
        {
            var source = dictionaries[i].Source?.OriginalString;
            if (source is not null && (source.EndsWith("Theme.Light.xaml", StringComparison.OrdinalIgnoreCase)
                                       || source.EndsWith("Theme.Dark.xaml", StringComparison.OrdinalIgnoreCase)))
            {
                dictionaries.RemoveAt(i);
            }
        }
        var dictionary = new System.Windows.ResourceDictionary
        {
            Source = new Uri("pack://application:,,,/SkyPaste;component/" + (dark ? DarkDictionary : LightDictionary), UriKind.Absolute),
        };
        dictionaries.Insert(0, dictionary);
        ThemeChanged?.Invoke();
    }

    public event Action? ThemeChanged;

    public static bool IsSystemDarkMode()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public void Dispose()
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
    }
}

/// <summary>HKCU\...\Run registration (macOS SMAppService equivalent).</summary>
public static class LaunchAtLoginService
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "SkyPaste";

    public static void Apply(bool launchAtLogin)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            if (key is null)
            {
                return;
            }
            if (launchAtLogin)
            {
                var exePath = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exePath))
                {
                    key.SetValue(ValueName, $"\"{exePath}\"");
                }
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception)
        {
            // Registry access failures are non-fatal.
        }
    }

    public static bool IsRegistered()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(ValueName) is not null;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
