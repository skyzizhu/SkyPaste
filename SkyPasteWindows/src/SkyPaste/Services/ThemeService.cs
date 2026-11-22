using Microsoft.Win32;
using Wpf.Ui.Appearance;
using SkyPaste.Core.Services;

namespace SkyPaste.Services;

/// <summary>
/// Appearance: Follow System / Light / Dark, implemented on WPF-UI's
/// ApplicationThemeManager (Fluent resources + dark window chrome) with our
/// app-specific brush dictionary swapped alongside it.
/// </summary>
public sealed class ThemeService : IDisposable
{
    private const string LightDictionary = "Views/Styles/Theme.Light.xaml";
    private const string DarkDictionary = "Views/Styles/Theme.Dark.xaml";

    private readonly AppSettingsService _settings;
    private ApplicationTheme _appliedTheme = ApplicationTheme.Light;

    public ThemeService(AppSettingsService settings)
    {
        _settings = settings;
        _settings.AppearanceSettingsChanged += ApplyCurrentSetting;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
    }

    public bool IsDarkMode => _appliedTheme == ApplicationTheme.Dark;

    public void ApplyCurrentSetting()
    {
        var dark = _settings.Appearance switch
        {
            AppAppearanceMode.Light => false,
            AppAppearanceMode.Dark => true,
            _ => IsSystemDarkMode(),
        };
        Apply(dark ? ApplicationTheme.Dark : ApplicationTheme.Light);
    }

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category == UserPreferenceCategory.General && _settings.Appearance == AppAppearanceMode.System)
        {
            ApplyCurrentSetting();
        }
    }

    private void Apply(ApplicationTheme theme)
    {
        if (theme == _appliedTheme && System.Windows.Application.Current?.Resources?.MergedDictionaries
                .Any(d => d.Source?.OriginalString?.EndsWith(
                    theme == ApplicationTheme.Dark ? DarkDictionary : LightDictionary,
                    StringComparison.OrdinalIgnoreCase) == true) == true)
        {
            return;
        }

        // WPF-UI swaps its Fluent dictionaries and repaints open windows.
        // Backdrop stays None: Mica is unavailable on Windows Server SKUs and
        // Win10 (CI renders transparent/black), and solid backgrounds keep the
        // look consistent everywhere. Rounded corners still come from DWM.

        ApplicationThemeManager.Apply(theme);

        // Swap our app-specific brush dictionary to match.
        var dictionaries = System.Windows.Application.Current?.Resources?.MergedDictionaries;
        if (dictionaries is not null)
        {
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
                Source = new Uri("pack://application:,,,/SkyPaste;component/" +
                    (theme == ApplicationTheme.Dark ? DarkDictionary : LightDictionary), UriKind.Absolute),
            };
            dictionaries.Add(dictionary);
        }

        _appliedTheme = theme;
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
