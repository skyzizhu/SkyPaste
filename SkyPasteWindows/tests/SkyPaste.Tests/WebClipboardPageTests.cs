using SkyPaste.Core.Services;
using Xunit;

namespace SkyPaste.Tests;

public class WebClipboardPageTests
{
    [Fact]
    public void PageContainsDeviceName()
    {
        var html = WebClipboardPageBuilder.Build("Skyzizhu 的 PC");
        Assert.Contains("Skyzizhu 的 PC", html);
        Assert.Contains("SkyPaste", html);
    }

    [Fact]
    public void PageEscapesDeviceNameHtml()
    {
        var html = WebClipboardPageBuilder.Build("<script>alert(1)</script>");
        Assert.DoesNotContain("<script>alert(1)</script>", html);
        Assert.Contains("&lt;script&gt;", html);
    }

    [Fact]
    public void PageDoesNotEmbedToken()
    {
        // The shell is served without auth; it must not leak the token.
        var html = WebClipboardPageBuilder.Build("MyPC");
        Assert.DoesNotContain("SECRET", html);
        Assert.Contains("localStorage", html); // token handled client-side
    }

    [Fact]
    public void PageReferencesApiEndpoints()
    {
        var html = WebClipboardPageBuilder.Build("PC");
        Assert.Contains("/paste", html);
        Assert.Contains("/pull", html);
        Assert.Contains("X-SkyPaste-Token", html);
    }

    [Fact]
    public void PageIsMobileFriendly()
    {
        var html = WebClipboardPageBuilder.Build("PC");
        Assert.Contains("viewport", html);
        Assert.Contains("navigator.clipboard", html);
    }
}
