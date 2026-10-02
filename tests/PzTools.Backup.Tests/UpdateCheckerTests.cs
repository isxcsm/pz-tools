using System.Net;
using System.Text.Json;
using PzTools.App.Core;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class UpdateCheckerTests
{
    [Theory]
    [InlineData("v0.2.1", "0.2.1")]
    [InlineData("0.3.0", "0.3.0")]
    [InlineData("V1.0", "1.0.0")]
    [InlineData("v0.3.0-beta", null)]
    [InlineData("release-20260927", null)]
    [InlineData("", null)]
    public void ParseVersion_TakesThreePartVersionsOnly(string tag, string? expected) =>
        Assert.Equal(expected, UpdateChecker.ParseVersion(tag)?.ToString());

    [Fact]
    public void ParseRelease_OpensOnlyThisRepositorysPages()
    {
        static UpdateRelease? Parse(string json) => UpdateChecker.ParseRelease(JsonDocument.Parse(json).RootElement);
        var own = Parse("""{"tag_name":"v0.3.0","html_url":"https://github.com/isxcsm/pz-tools/releases/tag/v0.3.0"}""");
        Assert.Equal("https://github.com/isxcsm/pz-tools/releases/tag/v0.3.0", own?.Page.ToString());
        foreach (var elsewhere in new[] { "https://evil.example/isxcsm/pz-tools/releases/x", "http://github.com/isxcsm/pz-tools/releases/x",
                     "https://github.com/someone/pz-tools/releases/x", "not a url" })
            Assert.Equal(UpdateChecker.ReleasesPage, Parse($$"""{"tag_name":"v0.3.0","html_url":"{{elsewhere}}"}""")?.Page);
        Assert.Null(Parse("""{"tag_name":"v0.3.0","prerelease":true}"""));
        Assert.Null(Parse("""{"tag_name":"v0.3.0","draft":true}"""));
        Assert.Null(Parse("""{"name":"no tag"}"""));
    }

    [Fact]
    public async Task NewerRelease_StaysOfferedUntilUpdated()
    {
        using var temp = new TempDirectory();
        var github = new FakeGitHub("v0.3.0");
        var path = temp.GetPath("update.json");
        var checker = new UpdateChecker(path, new Version(0, 2, 1, 0), github);
        Assert.Null(checker.Available);
        Assert.Null(checker.State.CheckedAt);

        var changed = 0;
        checker.Changed += () => changed++;
        await checker.CheckAsync(force: false);
        Assert.Equal(1, changed);
        Assert.Equal("v0.3.0", checker.Available?.Tag);
        Assert.Contains("PzTools/0.2.1", github.UserAgents.Single());

        // Known from the last check on the next run, without asking again.
        var reopened = new UpdateChecker(path, new Version(0, 2, 1), github);
        Assert.Equal("v0.3.0", reopened.Available?.Tag);
        Assert.Equal("https://github.com/isxcsm/pz-tools/releases/tag/v0.3.0", reopened.Available?.Page.ToString());

        // A newer one replaces it.
        github.Tag = "v0.3.1";
        await reopened.CheckAsync(force: true);
        Assert.Equal("v0.3.1", reopened.Available?.Tag);

        // Updated to it: nothing left to offer; the same release as this app is nothing either.
        Assert.Null(new UpdateChecker(path, new Version(0, 3, 1, 0), github).Available);
        Assert.Null(new UpdateChecker(path, new Version(0, 4, 0), github).Available);
    }

    [Fact]
    public async Task AutomaticCheck_AsksAtMostOnceAnInterval()
    {
        using var temp = new TempDirectory();
        var github = new FakeGitHub("v0.2.1");
        var clock = new ManualTime(DateTimeOffset.Parse("2026-10-03T00:00:00Z"));
        var path = temp.GetPath("update.json");
        var checker = new UpdateChecker(path, new Version(0, 2, 1), github, clock);
        await checker.CheckAsync(force: false);
        Assert.Null(checker.Available);
        Assert.NotNull(checker.State.CheckedAt);

        clock.Now += TimeSpan.FromHours(19);
        await new UpdateChecker(path, new Version(0, 2, 1), github, clock).CheckAsync(force: false);
        Assert.Equal(1, github.Requests);
        await checker.CheckAsync(force: true);
        Assert.Equal(2, github.Requests);
        clock.Now += UpdateChecker.Interval;
        await checker.CheckAsync(force: false);
        Assert.Equal(3, github.Requests);
    }

    [Fact]
    public async Task FailedCheck_KeepsTheLastAnswer()
    {
        using var temp = new TempDirectory();
        var github = new FakeGitHub("v0.3.0");
        var checker = new UpdateChecker(temp.GetPath("update.json"), new Version(0, 2, 1), github);
        await checker.CheckAsync(force: true);
        var checkedAt = checker.State.CheckedAt;

        github.Status = HttpStatusCode.Forbidden;
        await Assert.ThrowsAsync<HttpRequestException>(() => checker.CheckAsync(force: true));
        Assert.Equal("v0.3.0", checker.Available?.Tag);
        Assert.Equal(checkedAt, checker.State.CheckedAt);

        // No release at all is an answer, not a failure.
        github.Status = HttpStatusCode.NotFound;
        await checker.CheckAsync(force: true);
        Assert.Null(checker.Available);
    }

    [Fact]
    public void UnreadableState_IsACheckNeverMade()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("update.json");
        File.WriteAllText(path, "{ not json");
        var checker = new UpdateChecker(path, new Version(0, 2, 1), new FakeGitHub("v0.3.0"));
        Assert.Null(checker.State.CheckedAt);
        Assert.Null(checker.Available);
    }

    [Fact]
    public async Task Setting_DefaultsOnAndRoundTrips()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        Assert.True(service.Load().CheckForUpdates);
        Directory.CreateDirectory(service.RuntimeRoot);
        File.WriteAllText(service.SettingsPath, "[ui]\ncheck_updates = false\n");
        Assert.False(service.Load().CheckForUpdates);

        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var initial = AppSettings.CreateDefault() with { SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups") };
        await service.SaveAndApplyAsync(initial, scheduler);
        Assert.True(new AppSettingsService(service.RuntimeRoot).Load().CheckForUpdates);
        await service.SaveAndApplyAsync(initial with { CheckForUpdates = false }, scheduler);
        Assert.False(new AppSettingsService(service.RuntimeRoot).Load().CheckForUpdates);
    }

    private sealed class FakeGitHub(string tag) : HttpMessageHandler
    {
        public string Tag { get; set; } = tag;
        public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
        public int Requests { get; private set; }
        public List<string> UserAgents { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            UserAgents.Add(request.Headers.UserAgent.ToString());
            Assert.Equal("https://api.github.com/repos/isxcsm/pz-tools/releases/latest", request.RequestUri?.ToString());
            var body = $$"""{"tag_name":"{{Tag}}","html_url":"https://github.com/isxcsm/pz-tools/releases/tag/{{Tag}}","draft":false,"prerelease":false}""";
            return Task.FromResult(new HttpResponseMessage(Status) { Content = new StringContent(body) });
        }
    }

    private sealed class ManualTime(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
