using SkyPaste.Core.Core;
using Xunit;

namespace SkyPaste.Tests;

public class ClassificationTests
{
    // ---- email -----------------------------------------------------------

    [Theory]
    [InlineData("user@example.com", true)]
    [InlineData("first.last+tag@sub.domain.co", true)]
    [InlineData("not-an-email", false)]
    [InlineData("missing@tld", false)]
    [InlineData("has space@example.com", false)]
    [InlineData("@example.com", false)]
    public void EmailDetection(string input, bool expected)
    {
        Assert.Equal(expected, Classification.NormalizedEmailAddress(input) is not null);
    }

    // ---- URL -------------------------------------------------------------

    [Theory]
    [InlineData("https://example.com/path", true)]
    [InlineData("http://example.com", true)]
    [InlineData("example.com", true)]
    [InlineData("example.com/path?q=1", true)]
    [InlineData("192.168.1.1", true)]
    [InlineData("localhost", true)]
    [InlineData("https://localhost:8080/admin", true)]
    [InlineData("plain text sentence", false)]
    [InlineData("two words .com", false)]
    [InlineData("just word", false)]
    [InlineData("a.b", false)] // single-char TLD label invalid
    public void UrlDetection(string input, bool expected)
    {
        Assert.Equal(expected, Classification.LooksLikeUrl(input));
    }

    [Fact]
    public void HostValidation()
    {
        Assert.True(Classification.IsLikelyWebHost("example.com"));
        Assert.True(Classification.IsLikelyWebHost("sub.domain.example.co.uk"));
        Assert.True(Classification.IsLikelyWebHost("localhost"));
        Assert.True(Classification.IsLikelyWebHost("10.0.0.1"));
        Assert.False(Classification.IsLikelyWebHost("999.1.1.1"));
        Assert.False(Classification.IsLikelyWebHost("example.c"));
        Assert.False(Classification.IsLikelyWebHost("nosuchhost"));
        Assert.False(Classification.IsLikelyWebHost("-bad-.com"));
    }

    // ---- code ------------------------------------------------------------

    [Fact]
    public void MultiLineCodeDetected()
    {
        const string code = """
            func greet(name: String) -> String {
                return "Hello, \(name)"
            }
            """;
        Assert.True(Classification.LooksLikeCode(code, knownUrl: false));
    }

    [Fact]
    public void SqlDetected()
    {
        const string sql = "select id, name from users where age > 18;";
        Assert.True(Classification.LooksLikeCode(sql, knownUrl: false));
    }

    [Fact]
    public void NaturalLanguageNotCode()
    {
        const string text = "This is a normal sentence that we wrote and that this with the meaning of life";
        Assert.False(Classification.LooksLikeCode(text, knownUrl: false));
    }

    [Fact]
    public void UrlIsNotCode()
    {
        Assert.False(Classification.LooksLikeCode("https://example.com/very/long/path", knownUrl: true));
    }

    [Fact]
    public void ShortTextIsNotCode()
    {
        Assert.False(Classification.LooksLikeCode("hi", knownUrl: false));
    }

    [Fact]
    public void JsonIsCode()
    {
        const string json = """{"name": "test", "items": [1, 2, 3], "nested": {"a": true}}""";
        Assert.True(Classification.LooksLikeCode(json, knownUrl: false));
    }

    [Fact]
    public void HtmlIsCode()
    {
        Assert.True(Classification.LooksLikeCode("<div class=\"hero\">hello</div>", knownUrl: false));
    }

    [Fact]
    public void ImportStatementIsCode()
    {
        Assert.True(Classification.LooksLikeCode("import Foundation", knownUrl: false));
        Assert.True(Classification.LooksLikeCode("const x = require('fs');", knownUrl: false));
    }
}
