using SkyPaste.Core.Core;
using SkyPaste.Core.Models;
using Xunit;

namespace SkyPaste.Tests;

public class ClipboardItemTests
{
    [Fact]
    public void TextTitleTruncatesAt90Chars()
    {
        var shortItem = TestItems.Text("short text");
        Assert.Equal("short text", shortItem.Title);

        var longText = new string('a', 120);
        var longItem = TestItems.Text(longText);
        Assert.Equal(new string('a', 90) + "...", longItem.Title);
    }

    [Fact]
    public void UrlTitleUsesHostAndPath()
    {
        var item = TestItems.Text("https://docs.microsoft.com/dotnet/api/system.string?view=net-8.0");
        Assert.Equal("docs.microsoft.com/dotnet/api/system.string", item.Title);
    }

    [Fact]
    public void EmailItemClassifiedFirst()
    {
        var item = TestItems.Text("user@example.com");
        Assert.True(item.IsEmail);
        Assert.False(item.IsUrl);
        Assert.False(item.IsPlainText);
        Assert.Equal("user@example.com", item.Title);
        Assert.NotNull(item.MailtoUrl);
    }

    [Fact]
    public void ImageSubtitleShowsKb()
    {
        var data = new byte[2048];
        var item = TestItems.Image(data, "screenshot.png");
        Assert.True(item.IsImage);
        Assert.Equal("screenshot.png", item.Title);
        Assert.Contains("2", item.Subtitle); // 2 KB
    }

    [Fact]
    public void SearchIndexIncludesAliases()
    {
        var item = TestItems.Text("hello world");
        Assert.Contains("text", item.SearchIndex);
        Assert.Contains("文本", item.SearchIndex);
        Assert.Contains("local", item.SearchIndex);
        Assert.Contains("hello world", item.SearchIndex);
    }

    [Fact]
    public void SearchableTextAppendsFavoriteWords()
    {
        var fav = TestItems.Text("hello", favorite: true);
        Assert.Contains("收藏", fav.SearchableText);
        Assert.True(new SearchQuery("收藏").Matches(fav));
    }

    [Fact]
    public void DeviceItemKeepsDeviceNameInsteadOfSourceApp()
    {
        var item = new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromText("hi"), "txt:hi",
            ClipboardSource.LanDevice,
            new ClipboardSourceApp("device-1", "Pixel 8"));
        Assert.Null(item.SourceApp);
        Assert.Equal("Pixel 8", item.DeviceName);
        Assert.True(item.Source.IsDeviceSynced());
    }

    [Fact]
    public void SourceAlwaysNormalizesToLocalOrDevice()
    {
        var item = new ClipboardItem(
            Guid.NewGuid(), DateTime.UtcNow,
            ClipboardContent.FromText("hi"), "txt:hi",
            (ClipboardSource)99, null);
        Assert.Equal(ClipboardSource.LanDevice, item.Source);
    }
}
