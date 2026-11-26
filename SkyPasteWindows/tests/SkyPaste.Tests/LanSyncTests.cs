using System.Net;
using System.Text;
using System.Text.Json;
using SkyPaste.Core.Data;
using SkyPaste.Core.Services;
using Xunit;

namespace SkyPaste.Tests;

public class LanSyncTests
{
    [Fact]
    public async Task PairingPageAndUtf8TransferUseTheSameProtocolAsMac()
    {
        using var fixture = new DatabaseFixture();
        var settings = new AppSettingsService(fixture.Directory);
        settings.LanSyncToken = "integration-test-token";
        var store = new ClipboardStore(
            new ClipboardDatabase(fixture.HistoryPath),
            new StatisticsDatabase(fixture.StatisticsPath),
            settings);
        store.Add(TestItems.Text("from PC"));

        using var service = new LanSyncService(settings, store);
        using var server = new SimpleHttpServer(0, service.HandleRequest);
        using var lifetime = new CancellationTokenSource();
        server.Start(lifetime.Token);
        using var client = new HttpClient
        {
            BaseAddress = new Uri($"http://127.0.0.1:{server.LocalPort}"),
            Timeout = TimeSpan.FromSeconds(3),
        };

        using var page = await client.GetAsync("/");
        Assert.Equal("text/html", page.Content.Headers.ContentType?.MediaType);
        Assert.DoesNotContain(settings.LanSyncToken, await page.Content.ReadAsStringAsync());
        using var denied = await client.GetAsync("/pull");
        Assert.Equal(HttpStatusCode.Unauthorized, denied.StatusCode);

        client.DefaultRequestHeaders.Add("X-SkyPaste-Token", settings.LanSyncToken);
        using var body = new StringContent(
            """{"text":"从手机复制 🌟","device":"手机","createdAt":"2026-11-26T11:00:00Z"}""",
            Encoding.UTF8, "application/json");
        using var sent = await client.PostAsync("/paste", body);
        Assert.Equal(HttpStatusCode.OK, sent.StatusCode);
        Assert.Contains(store.Items, item => item.TextValue == "从手机复制 🌟");

        using var pulled = await client.GetAsync("/pull");
        Assert.Equal(HttpStatusCode.OK, pulled.StatusCode);
        using var items = JsonDocument.Parse(await pulled.Content.ReadAsStringAsync());
        var local = items.RootElement.EnumerateArray().Single();
        Assert.Equal("from PC", local.GetProperty("text").GetString());
        Assert.Matches(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", local.GetProperty("createdAt").GetString()!);
    }
}
