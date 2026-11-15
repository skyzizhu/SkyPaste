using SkyPaste.Core.Core;
using SkyPaste.Core.Models;
using Xunit;

namespace SkyPaste.Tests;

public class PinyinSearchTests
{
    [Theory]
    [InlineData("截图", "JT")]
    [InlineData("搜索工具", "SSGJ")]
    [InlineData("中国", "ZG")]
    [InlineData("北京上海", "BJSH")]
    public void CommonHanziInitials(string text, string expected)
    {
        Assert.Equal(expected, PinyinInitials.ToInitials(text));
    }

    [Fact]
    public void AsciiPassesThrough()
    {
        Assert.Equal("ABC123", PinyinInitials.ToInitials("abc123"));
    }

    [Fact]
    public void MixedTextKeepsLatinAndInitials()
    {
        // "AI 截图" -> latin kept + initials
        Assert.Equal("AIJT", PinyinInitials.ToInitials("AI 截图"));
    }

    [Fact]
    public void UnmappedCharsContributeNothing()
    {
        // Rare chars outside GB2312 table -> empty
        Assert.Equal(string.Empty, PinyinInitials.ToInitials("㙂㙂"));
        Assert.Equal(string.Empty, PinyinInitials.ToInitials(""));
    }

    [Fact]
    public void SearchQueryHitsViaInitials()
    {
        var item = TestItems.Text("这是一个截图工具的说明");
        // Full pinyin of a word inside the index: initials of whole index include "ZS YG JT GJ"
        Assert.True(new SearchQuery("jtgj").Matches(item) || new SearchQuery("jt").Matches(item),
            "initials query should hit");
    }

    [Fact]
    public void SearchQueryInitialsCaseInsensitive()
    {
        var item = TestItems.Text("屏幕截图");
        Assert.True(new SearchQuery("PMJT").Matches(item));
        Assert.True(new SearchQuery("pmjt").Matches(item));
    }
}
