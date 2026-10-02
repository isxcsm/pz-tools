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
    /// <summary>Each card that can be previewed, by key, with the name the settings list it under.</summary>
    internal static IReadOnlyList<(string Key, string Name)> CardPreviews { get; } =
    [
        ("blocked", "Windows 보안 차단"),
        ("game-link", "게임 연결 끊김"),
        ("game-restart", "게임 다시 시작 필요"),
        ("game-elevation", "게임 연결: 관리자 권한"),
        ("game-disabled", "게임 연결: 실행 옵션"),
        ("projectors", "불러오기 실패"),
        ("update", "새 버전"),
        ("notice-success", "결과: 성공"),
        ("notice-info", "결과: 안내"),
        ("notice-warning", "결과: 경고"),
        ("notice-error", "결과: 오류"),
    ];

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
            case "game-link" or "game-restart" or "game-elevation" or "game-disabled":
                previewGameLink = new GameLinkView(LinkUnavailable: true, RestartRequired: key == "game-restart", Cause: key switch
                {
                    "game-elevation" => Process.Contracts.GameRuntime.RuntimeObservation.ElevationReason,
                    "game-disabled" => Process.Contracts.GameRuntime.RuntimeObservation.AttachDisabledReason,
                    _ => null,
                });
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
            case "update":
                var current = App.Updates?.Current ?? new Version(0, 0, 0);
                var next = new Version(current.Major, current.Minor + 1, 0);
                previewUpdate = new UpdateRelease(next, "v" + next.ToString(3), UpdateChecker.ReleasesPage);
                ApplyUpdate();
                break;
            // The result cards expire like real ones. Unlike a real warning or error, they leave nothing in the log.
            case "notice-success":
                PreviewNotice(OperationStatus.Succeeded, "ProfilerNavigation", "ProfileResultsCopied");
                break;
            case "notice-info":
                PreviewNotice(OperationStatus.Busy, "HotKeysTitle", "HotKeyNoSave");
                break;
            case "notice-warning":
                PreviewNotice(OperationStatus.Degraded, "PathSettings.Header", "OperationError.FileMissing");
                break;
            case "notice-error":
                PreviewNotice(OperationStatus.Failed, "ProfilerNavigation", "ProfileLoadFailed");
                break;
        }
    }

    private void PreviewNotice(OperationStatus status, string title, string message)
    {
        notices.Add(new(Guid.NewGuid().ToString("N"), Localizer.Get(title), Localizer.Get(message), status, DateTimeOffset.UtcNow));
        RefreshOperationCards();
    }

    /// <summary>Puts every previewed card back to what the real state shows.</summary>
    internal void ClearCardPreviews()
    {
        (previewBlocked, previewGameLink, previewProjectors, previewUpdate) = (null, null, null, null);
        var views = App.Host?.Views;
        ApplyBlockedComponents(views?.ReadIfChanged<BlockedComponentsView>(AppHost.BlockedComponentsViewKey, 0).Snapshot ?? new([]));
        ApplyGameLink(views?.ReadIfChanged<GameLinkView>(AppHost.GameLinkViewKey, 0).Snapshot ?? GameLinkView.Available);
        ApplyProjectorHealth();
        ApplyUpdate();
    }

    // PZTOOLS_PREVIEW_CARDS=blocked,update (or "all") shows those cards from the start, for a run driven by a script.
    private void PreviewCardsFromEnvironment()
    {
        if (Environment.GetEnvironmentVariable("PZTOOLS_PREVIEW_CARDS") is not { Length: > 0 } text) return;
        var keys = text.Trim() == "all" ? CardPreviews.Select(card => card.Key)
            : text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var key in keys) PreviewCard(key);
    }
}
#endif
