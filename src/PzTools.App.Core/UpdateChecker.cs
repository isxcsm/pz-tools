using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PzTools.App.Core;

/// <summary>A published release: its version, its tag as written, and the page it is downloaded from.</summary>
public sealed record UpdateRelease(Version Version, string Tag, Uri Page);

/// <summary>What the app knows about its updates, kept between runs: when it last asked, and the newest release then.</summary>
public sealed record UpdateState(DateTimeOffset? CheckedAt = null, UpdateRelease? Latest = null);

/// <summary>
/// Asks GitHub for the latest release of PZ Tools, no more than once a day unless asked, and keeps the answer. Nothing
/// is downloaded or installed: a newer release stays offered, one click from its page in the browser, until the app is
/// updated to it.
/// </summary>
public sealed class UpdateChecker
{
    public const string Repository = "isxcsm/pz-tools";
    /// <summary>The releases page, for when a release names no page of its own in this repository.</summary>
    public static readonly Uri ReleasesPage = new($"https://github.com/{Repository}/releases/latest");
    private static readonly Uri LatestRelease = new($"https://api.github.com/repos/{Repository}/releases/latest");
    /// <summary>An automatic check waits this long after the last one; GitHub allows 60 unsigned requests an hour.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromHours(20);

    private readonly string statePath;
    private readonly HttpMessageHandler? handler;
    private readonly TimeProvider time;
    private readonly SemaphoreSlim gate = new(1, 1);
    private UpdateState state;

    public UpdateChecker(string statePath, Version current, HttpMessageHandler? handler = null, TimeProvider? time = null)
    {
        this.statePath = Path.GetFullPath(statePath);
        Current = Normalize(current);
        this.handler = handler;
        this.time = time ?? TimeProvider.System;
        state = Read(this.statePath);
    }

    /// <summary>Raised after the state changed, on whichever thread changed it.</summary>
    public event Action? Changed;

    public Version Current { get; }
    public UpdateState State => state;

    /// <summary>The newest release when it is newer than this app.</summary>
    public UpdateRelease? Available => state.Latest is { } latest && latest.Version > Current ? latest : null;

    /// <summary>
    /// Asks GitHub unless an automatic check already did within <see cref="Interval"/>. Failures (no connection,
    /// GitHub refusing) are thrown for the caller to say or ignore; the state keeps the last answer.
    /// </summary>
    public async Task CheckAsync(bool force, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (!force && state.CheckedAt is { } last && time.GetUtcNow() - last < Interval) return;
            var latest = await FetchAsync(cancellationToken);
            await SaveAsync(state with { CheckedAt = time.GetUtcNow(), Latest = latest }, cancellationToken);
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }

    private async Task<UpdateRelease?> FetchAsync(CancellationToken cancellationToken)
    {
        using var client = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        client.Timeout = TimeSpan.FromSeconds(15);
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestRelease);
        // GitHub refuses requests without a user agent.
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("PzTools", Current.ToString(3)));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        using var response = await client.SendAsync(request, cancellationToken);
        // No release published yet.
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        await using var body = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var document = await JsonDocument.ParseAsync(body, cancellationToken: cancellationToken);
        return ParseRelease(document.RootElement);
    }

    /// <summary>
    /// The release GitHub calls latest (never a draft or a pre-release), or none when its tag is no version. Its page is
    /// opened only when it is in this repository.
    /// </summary>
    public static UpdateRelease? ParseRelease(JsonElement release)
    {
        if (release.ValueKind != JsonValueKind.Object
            || !release.TryGetProperty("tag_name", out var tagValue) || tagValue.GetString() is not { } tag
            || ParseVersion(tag) is not { } version)
            return null;
        if (release.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) return null;
        if (release.TryGetProperty("prerelease", out var pre) && pre.ValueKind == JsonValueKind.True) return null;
        var page = PageOf(release.TryGetProperty("html_url", out var url) && url.ValueKind == JsonValueKind.String ? url.GetString() : null);
        return new UpdateRelease(version, tag, page);
    }

    // Only a release page of this repository is opened in the browser; anything else becomes the releases page.
    private static Uri PageOf(string? text) =>
        Uri.TryCreate(text, UriKind.Absolute, out var parsed)
        && parsed.Scheme == Uri.UriSchemeHttps && parsed.Host == "github.com"
        && parsed.AbsolutePath.StartsWith($"/{Repository}/releases/", StringComparison.Ordinal)
            ? parsed : ReleasesPage;

    /// <summary>"v1.2.3" or "1.2.3" as a version of three parts; a pre-release ("1.2.3-beta") or anything else is none.</summary>
    public static Version? ParseVersion(string tag)
    {
        var text = tag.StartsWith('v') || tag.StartsWith('V') ? tag[1..] : tag;
        return text.Contains('-') || !Version.TryParse(text, out var version) ? null : Normalize(version);
    }

    // 0.2.1 and 0.2.1.0 are the same release.
    private static Version Normalize(Version version) => new(version.Major, version.Minor, Math.Max(0, version.Build));

    private async Task SaveAsync(UpdateState next, CancellationToken cancellationToken)
    {
        var stored = new StoredState(next.CheckedAt, next.Latest?.Tag, next.Latest?.Page.ToString());
        await AtomicTextFile.WriteAsync(statePath, JsonSerializer.Serialize(stored, JsonOptions), cancellationToken);
        state = next;
    }

    // An unreadable file is a check never made: it is written again after the next one.
    private static UpdateState Read(string path)
    {
        try
        {
            if (!File.Exists(path)) return new();
            var stored = JsonSerializer.Deserialize<StoredState>(File.ReadAllText(path), JsonOptions);
            if (stored is null) return new();
            UpdateRelease? latest = null;
            if (stored.LatestTag is { } tag && ParseVersion(tag) is { } version)
                latest = new UpdateRelease(version, tag, PageOf(stored.LatestPage));
            return new UpdateState(stored.CheckedAt, latest);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new();
        }
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private sealed record StoredState(DateTimeOffset? CheckedAt, string? LatestTag, string? LatestPage);
}
