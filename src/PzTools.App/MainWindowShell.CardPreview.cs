#if PZTOOLS_DEV_TOOLS
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;
using PzTools.Projections;

namespace PzTools.App;

/// <summary>
/// Shows the sidebar's cards on demand, for a look at their design and a press of their buttons, without the state that
/// raises them (a blocked component, a lost game, a new release). Only in a developer build: a published app compiles
/// none of this. The cards go through the same code as the real state, so what is previewed is what users see; whether
/// the state is detected is for the tests.
/// </summary>
public sealed partial class MainWindowShell
{
    /// <summary>Each card that can be previewed, by key.</summary>
    internal static IReadOnlyList<string> CardPreviews { get; } =
    [
        "install", "blocked", "game-link", "game-restart", "game-disabled", "projectors", "game-memory", "update",
        "notice-success", "notice-info", "notice-warning", "notice-error",
    ];

    /// <summary>The name the settings list a card under: its own title (or message) in the app's language.</summary>
    internal static string CardPreviewName(string key) => key switch
    {
        "install" => Localizer.Get("InstallBrokenTitle"),
        "blocked" => Localizer.Get("ComponentBlockedTitle"),
        "game-link" => Localizer.Get("GameLinkCardTitle"),
        "game-restart" => Localizer.Get("GameLinkRestartTitle"),
        "game-disabled" => Localizer.Get("GameLinkCardDisabledMessage"),
        "projectors" => Localizer.Get("SavesUnavailable"),
        "game-memory" => Localizer.Format("GameMemoryRevertedTitleFormat", SettingsPage.Size(PreviewMemory.MaximumMegabytes!.Value)),
        "update" => Localizer.Format("UpdateCardFormat", "v" + PreviewRelease.ToString(3)),
        _ => NoticeContents.TryGetValue(key, out var notice) ? Localizer.Get(notice.Message) : key,
    };

    private static readonly GameMemoryState PreviewMemory = new(GameMemoryStatus.Reverted, null, 3072, 3072, 8192);

    private static Version PreviewRelease
    {
        get
        {
            var current = ((App)Microsoft.UI.Xaml.Application.Current).Updates?.Current ?? new Version(0, 0, 0);
            return new Version(current.Major, current.Minor + 1, 0);
        }
    }

    // The result cards borrow real titles and messages, one of each kind.
    private static readonly Dictionary<string, (OperationStatus Status, string Title, string Message)> NoticeContents = new()
    {
        ["notice-success"] = (OperationStatus.Succeeded, "ProfilerNavigation", "ProfileReportCopied"),
        ["notice-info"] = (OperationStatus.Busy, "HotKeysTitle", "HotKeyNoSave"),
        ["notice-warning"] = (OperationStatus.Degraded, "PathSettings.Header", "OperationError.FileMissing"),
        ["notice-error"] = (OperationStatus.Failed, "ProfilerNavigation", "ProfileLoadFailed"),
    };

    /// <summary>Shows one card as if its state had arisen; it stays until <see cref="ClearCardPreviews"/>.</summary>
    internal void PreviewCard(string key)
    {
        switch (key)
        {
            case "blocked":
                previewBlocked = new BlockedComponentsView(["PzTools.Backup.Worker.exe", "java.exe"]);
                dismissedBlockedComponents = null;
                ApplyBlockedComponents(previewBlocked);
                break;
            case "game-link" or "game-restart" or "game-disabled":
                previewGameLink = new GameLinkView(LinkUnavailable: true, RestartRequired: key == "game-restart",
                    Cause: key == "game-disabled" ? Process.Contracts.GameRuntime.RuntimeObservation.AttachDisabledReason : null);
                gameLinkDismissed = false;
                ApplyGameLink(previewGameLink);
                break;
            case "projectors":
                previewProjectors = new ProjectorHealthView(
                [
                    new ProjectorStatus("state", ProjectorHealth.Faulted, "preview", DateTimeOffset.UtcNow),
                    new ProjectorStatus("backup", ProjectorHealth.Faulted, "preview", DateTimeOffset.UtcNow),
                    new ProjectorStatus("details", ProjectorHealth.Faulted, "preview", DateTimeOffset.UtcNow),
                ]);
                ApplyProjectorHealth();
                break;
            case "install":
                previewInstallProblem = true;
                installDismissed = false;
                ApplyInstallProblem();
                break;
            case "game-memory":
                previewGameMemory = PreviewMemory;
                gameMemoryDismissed = null;
                ApplyGameMemory();
                break;
            case "update":
                var next = PreviewRelease;
                previewUpdate = new UpdateRelease(next, "v" + next.ToString(3), UpdateChecker.ReleasesPage);
                ApplyUpdate();
                break;
            // The result cards expire like real ones. Unlike a real warning or error, they leave nothing in the log.
            case var notice when NoticeContents.TryGetValue(notice, out var content):
                notices.Add(new(Guid.NewGuid().ToString("N"), Localizer.Get(content.Title), Localizer.Get(content.Message),
                    content.Status, DateTimeOffset.UtcNow));
                RefreshOperationCards();
                break;
        }
    }

    /// <summary>Puts every previewed card back to what the real state shows.</summary>
    internal void ClearCardPreviews()
    {
        (previewBlocked, previewGameLink, previewProjectors, previewUpdate, previewGameMemory) = (null, null, null, null, null);
        previewInstallProblem = false;
        var views = App.Host?.Views;
        ApplyBlockedComponents(views?.ReadIfChanged<BlockedComponentsView>(AppHost.BlockedComponentsViewKey, 0).Snapshot ?? new([]));
        ApplyGameLink(views?.ReadIfChanged<GameLinkView>(AppHost.GameLinkViewKey, 0).Snapshot ?? GameLinkView.Available);
        ApplyProjectorHealth();
        ApplyUpdate();
        ApplyGameMemory();
        ApplyInstallProblem();
    }

    // PZTOOLS_PREVIEW_CARDS=blocked,update (or "all") shows those cards from the start, for a run driven by a script.
    private void PreviewCardsFromEnvironment()
    {
        if (Environment.GetEnvironmentVariable("PZTOOLS_PREVIEW_CARDS") is not { Length: > 0 } text) return;
        var keys = text.Trim() == "all" ? CardPreviews
            : text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var key in keys) PreviewCard(key);
    }
}
#endif
