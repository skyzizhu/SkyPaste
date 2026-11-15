using SkyPaste.Core.Core;
using SkyPaste.Core.Models;
using Xunit;

namespace SkyPaste.Tests;

public static class TestItems
{
    public static ClipboardItem Text(string text, DateTime? createdAtUtc = null, bool favorite = false,
        ClipboardSource source = ClipboardSource.Local, ClipboardSourceApp? app = null)
    {
        return new ClipboardItem(
            Guid.NewGuid(),
            createdAtUtc ?? DateTime.UtcNow,
            ClipboardContent.FromText(text),
            Fingerprint.ForText(text),
            source,
            app,
            favorite);
    }

    public static ClipboardItem Image(byte[] data, string? name = null, DateTime? createdAtUtc = null)
    {
        return new ClipboardItem(
            Guid.NewGuid(),
            createdAtUtc ?? DateTime.UtcNow,
            ClipboardContent.FromImage(data, name, data.LongLength, previewOnly: false),
            Fingerprint.ForImage(data),
            ClipboardSource.Local,
            null);
    }
}

public class SearchQueryTests
{
    [Fact]
    public void SubstringMatchIsCaseInsensitiveAndAnded()
    {
        var item = TestItems.Text("Hello World Special");
        Assert.True(new SearchQuery("hello world").Matches(item));
        Assert.True(new SearchQuery("SPECIAL").Matches(item));
        Assert.False(new SearchQuery("hello missing").Matches(item));
    }

    [Fact]
    public void ChineseKeywordHitsIndex()
    {
        var item = TestItems.Text("这是一段中文内容");
        Assert.True(new SearchQuery("中文").Matches(item));
        Assert.False(new SearchQuery("英文").Matches(item));
    }

    [Fact]
    public void FavoritesToken()
    {
        var fav = TestItems.Text("favorite item", favorite: true);
        var plain = TestItems.Text("favorite item", favorite: false);
        Assert.True(new SearchQuery("fav").Matches(fav));
        Assert.False(new SearchQuery("fav").Matches(plain));
        Assert.True(new SearchQuery("收藏").Matches(fav));
    }

    [Fact]
    public void TypeTokens()
    {
        var text = TestItems.Text("just words");
        var url = TestItems.Text("https://example.com");
        var email = TestItems.Text("user@example.com");

        Assert.True(new SearchQuery("type:text").Matches(text));
        Assert.False(new SearchQuery("type:text").Matches(url));
        Assert.True(new SearchQuery("type:url").Matches(url));
        Assert.True(new SearchQuery("is:url").Matches(url));
        Assert.True(new SearchQuery("type:email").Matches(email));
        Assert.True(new SearchQuery("type:link").Matches(url));
    }

    [Fact]
    public void SourceTokens()
    {
        var local = TestItems.Text("content", source: ClipboardSource.Local);
        var device = TestItems.Text("content", source: ClipboardSource.LanDevice,
            app: new ClipboardSourceApp("phone-1", "iPhone"));

        Assert.True(new SearchQuery("source:local").Matches(local));
        Assert.False(new SearchQuery("source:local").Matches(device));
        Assert.True(new SearchQuery("source:phone").Matches(device));
        Assert.True(new SearchQuery("source:device").Matches(device));
    }

    [Fact]
    public void TodayTokenMatchesTodayItem()
    {
        var now = TestItems.Text("fresh", DateTime.UtcNow);
        var old = TestItems.Text("old", DateTime.UtcNow.AddDays(-3));
        Assert.True(new SearchQuery("today").Matches(now));
        Assert.False(new SearchQuery("today").Matches(old));
    }

    [Fact]
    public void MixedQuery()
    {
        var item = TestItems.Text("meeting notes about deploy", DateTime.UtcNow, favorite: true);
        Assert.True(new SearchQuery("deploy fav").Matches(item));
        Assert.True(new SearchQuery("deploy fav today").Matches(item));
        Assert.False(new SearchQuery("deploy yesterday").Matches(item));
    }

    [Fact]
    public void DeviceNameIndexed()
    {
        var device = TestItems.Text("from phone", source: ClipboardSource.LanDevice,
            app: new ClipboardSourceApp("dev-1", "My iPhone"));
        Assert.True(new SearchQuery("iphone").Matches(device));
        Assert.True(new SearchQuery("my iphone").Matches(device));
    }
}

public class FingerprintTests
{
    [Fact]
    public void TextFingerprint()
    {
        Assert.Equal("txt:hello", Fingerprint.ForText("hello"));
        // Duplicate detection relies on exact text equality.
        Assert.Equal(Fingerprint.ForText("same"), Fingerprint.ForText("same"));
        Assert.NotEqual(Fingerprint.ForText("same"), Fingerprint.ForText("same "));
    }

    [Fact]
    public void ImageFingerprintUsesPrefixAndLength()
    {
        var a = new byte[100];
        var b = new byte[100];
        Array.Fill(a, (byte)1);
        Array.Fill(b, (byte)1);
        Assert.Equal(Fingerprint.ForImage(a), Fingerprint.ForImage(b));

        b[63] = 9; // within the 64-byte prefix -> different fingerprint
        Assert.NotEqual(Fingerprint.ForImage(a), Fingerprint.ForImage(b));

        var c = new byte[200];
        Array.Fill(c, (byte)1);
        Assert.NotEqual(Fingerprint.ForImage(a), Fingerprint.ForImage(c)); // same prefix, different length
    }

    [Fact]
    public void FileFingerprint()
    {
        Assert.Equal("file:C:\\a.txt|C:\\b.txt", Fingerprint.ForFiles(new[] { @"C:\a.txt", @"C:\b.txt" }));
    }
}

public class ClipboardFilterTests
{
    [Fact]
    public void DefaultOrder()
    {
        var order = ClipboardFilterExtensions.DefaultDisplayOrder;
        Assert.Equal(ClipboardFilter.All, order[0]);
        Assert.Equal(ClipboardFilter.Favorites, order[^1]);
        Assert.Equal(9, order.Count);
    }

    [Fact]
    public void NormalizeOrderDropsFixedAndDuplicatesAndAppendsMissing()
    {
        var raw = new[] { ClipboardFilter.Url, ClipboardFilter.All, ClipboardFilter.Url, ClipboardFilter.Text };
        var normalized = ClipboardFilterExtensions.NormalizeReorderableOrder(raw);
        Assert.Equal(new[] { ClipboardFilter.Url, ClipboardFilter.Text, ClipboardFilter.Image, ClipboardFilter.File, ClipboardFilter.Folder, ClipboardFilter.Code, ClipboardFilter.Email },
            normalized);
    }

    [Fact]
    public void FilterMatching()
    {
        var text = TestItems.Text("words");
        Assert.True(ClipboardFilter.Text.Matches(text));
        Assert.False(ClipboardFilter.Code.Matches(text));
        Assert.False(ClipboardFilter.Favorites.Matches(text));

        var fav = TestItems.Text("words", favorite: true);
        Assert.True(ClipboardFilter.Favorites.Matches(fav));

        var url = TestItems.Text("https://example.com");
        Assert.True(ClipboardFilter.Url.Matches(url));
        Assert.False(ClipboardFilter.Text.Matches(url));
    }
}

public class SensitiveContentFilterTests
{
    private static ClipboardSourceApp? App(string name) =>
        new("com.test.app", name);

    [Fact]
    public void DisabledFilterPassesEverything()
    {
        Assert.False(SensitiveContentFilter.ShouldExclude("123456", null, enabled: false));
    }

    [Theory]
    [InlineData("1Password")]
    [InlineData("com.agilebits.onepassword")]
    [InlineData("Bitwarden")]
    [InlineData("keepass")]
    public void PasswordManagerSourcesExcluded(string appName)
    {
        Assert.True(SensitiveContentFilter.ShouldExclude("some secret", App(appName), enabled: true));
    }

    [Theory]
    [InlineData("123456")]
    [InlineData("4821")]
    [InlineData("AB12CD")]
    [InlineData("Your verification code is 552211")]
    [InlineData("验证码 552211")]
    public void VerificationCodesExcluded(string text)
    {
        Assert.True(SensitiveContentFilter.ShouldExclude(text, App("Notepad"), enabled: true));
    }

    [Theory]
    [InlineData("4111 1111 1111 1111")]
    [InlineData("5500005555555559")]
    [InlineData("4012888888881881")]
    public void BankCardsExcluded(string text)
    {
        Assert.True(SensitiveContentFilter.ShouldExclude(text, null, enabled: true));
    }

    [Fact]
    public void NonLuhnDigitsPass()
    {
        Assert.False(SensitiveContentFilter.ShouldExclude("4111 1111 1111 1112", null, enabled: true));
    }

    [Theory]
    [InlineData("sk-abcdefghijklmnopqrstuvwxyz123456")]
    [InlineData("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz1234567890")]
    [InlineData("bearer abcdef1234567890abcdef123456")]
    [InlineData("-----BEGIN RSA PRIVATE KEY-----")]
    [InlineData("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4")]
    [InlineData("api_key = 0123456789abcdefXYZ")]
    [InlineData("0123456789abcdef0123456789abcdef")]
    public void TokensExcluded(string text)
    {
        Assert.True(SensitiveContentFilter.ShouldExclude(text, null, enabled: true));
    }

    [Fact]
    public void NormalTextPasses()
    {
        Assert.False(SensitiveContentFilter.ShouldExclude("meeting notes for tomorrow", App("Notepad"), enabled: true));
        Assert.False(SensitiveContentFilter.ShouldExclude("call me at 5pm", null, enabled: true));
    }
}
