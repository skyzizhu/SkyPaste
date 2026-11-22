using SkyPaste.Core.Services;
using Xunit;

namespace SkyPaste.Tests;

public class AppSettingsServiceTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(), "skypaste-settings-" + Guid.NewGuid().ToString("N"));

    public AppSettingsService MakeSettings() => new(_directory);

    public void Dispose()
    {
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    [Fact]
    public void DefaultsMatchMacApp()
    {
        var settings = MakeSettings();
        Assert.Equal(200, settings.HistoryLimit);
        Assert.Equal("V", settings.HotKeyKey);
        Assert.True(settings.HotKeyCtrl);
        Assert.True(settings.HotKeyShift);
        Assert.False(settings.HotKeyAlt);
        Assert.True(settings.LaunchAtLogin);
        Assert.False(settings.AutoPasteEnabled); // Mac App Store default: click only selects
        Assert.False(settings.PrivacyFilteringEnabled);
        Assert.False(settings.LanSyncEnabled);
        Assert.True(settings.LanSyncUploadEnabled);
        Assert.True(settings.LanSyncReceiveEnabled);
        Assert.Equal("system", settings.LanguageCode);
        Assert.Equal("system", settings.AppearanceMode);
        Assert.Equal("center", settings.PanelPosition);
    }

    [Fact]
    public void HistoryLimitClamped()
    {
        Assert.Equal(20, AppSettingsService.ClampHistoryLimit(1));
        Assert.Equal(200, AppSettingsService.ClampHistoryLimit(0));
        Assert.Equal(1000, AppSettingsService.ClampHistoryLimit(5000));
        Assert.Equal(60, AppSettingsService.ClampHistoryLimit(60));
    }

    [Fact]
    public void PanelPositionNormalized()
    {
        var settings = MakeSettings();
        settings.PanelPosition = "cursor";
        Assert.Equal("cursor", settings.PanelPosition);
        settings.PanelPosition = "remember";
        Assert.Equal("remember", settings.PanelPosition);
        settings.PanelPosition = "bogus";
        Assert.Equal("center", settings.PanelPosition);
    }

    [Fact]
    public void RoundTripPersists()
    {
        var settings = MakeSettings();
        settings.HistoryLimit = 500;
        settings.PanelPosition = "cursor";
        settings.LanguageCode = "zh-Hans";
        settings.AppearanceMode = "dark";
        settings.LanSyncEnabled = true;
        settings.LanSyncPort = 27000;
        settings.HotKeyKey = "P";
        settings.HotKeyAlt = true;
        settings.HotKeyCtrl = false;
        settings.IgnoredAppsInput = "notepad, 1password.exe";
        settings.FilterOrder = new List<string> { "Url", "Text" };

        var reopened = new AppSettingsService(_directory);
        Assert.Equal(500, reopened.HistoryLimit);
        Assert.Equal("cursor", reopened.PanelPosition);
        Assert.Equal("zh-Hans", reopened.LanguageCode);
        Assert.Equal("dark", reopened.AppearanceMode);
        Assert.True(reopened.LanSyncEnabled);
        Assert.Equal(27000, reopened.LanSyncPort);
        Assert.Equal("P", reopened.HotKeyKey);
        Assert.False(reopened.HotKeyCtrl);
        Assert.True(reopened.HotKeyAlt);
        Assert.Equal("notepad, 1password.exe", reopened.IgnoredAppsInput);
    }

    [Fact]
    public void FilterOrderNormalizedOnSet()
    {
        var settings = MakeSettings();
        settings.FilterOrder = new List<string> { "Url", "Url", "All", "Favorites", "Text" };
        // Fixed chips (All/Favorites) and duplicates are dropped; missing appended.
        Assert.Equal(new[] { "Url", "Text", "Image", "File", "Folder", "Code", "Email" },
            settings.FilterOrder);
    }

    [Fact]
    public void HotKeyDisplayText()
    {
        var settings = MakeSettings();
        Assert.Equal("Ctrl+Shift+V", settings.HotKeyDisplayText);
        settings.HotKeyCtrl = false;
        settings.HotKeyAlt = true;
        settings.HotKeyKey = "K";
        Assert.Equal("Shift+Alt+K", settings.HotKeyDisplayText);
    }

    [Fact]
    public void IgnoredAppsParsing()
    {
        var settings = MakeSettings();
        settings.IgnoredAppsInput = "Notepad.exe, \n  1password  ,";
        Assert.Equal(new HashSet<string> { "notepad.exe", "1password" }, settings.IgnoredApps);
    }

    [Fact]
    public void CorruptSettingsFileFallsBackToDefaults()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "settings.json"), "{ not valid json !!");
        var settings = new AppSettingsService(_directory);
        Assert.Equal(200, settings.HistoryLimit);
        Assert.Equal("system", settings.LanguageCode);
    }
}
