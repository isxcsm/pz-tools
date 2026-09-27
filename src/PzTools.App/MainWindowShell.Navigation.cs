using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace PzTools.App;

public sealed partial class MainWindowShell
{
    private readonly UISettings navigationUiSettings = new();
    private FrameworkElement? requestedContent;
    private FrameworkElement? displayedContent;
    private CompositionScopedBatch? contentTransitionBatch;
    private ScalarKeyFrameAnimation? contentFade;
    private Vector3KeyFrameAnimation? contentRise;
    private Action? contentTransitionCompleted;
    private bool contentExiting;

    private void NavigateToContent(FrameworkElement page)
    {
        if (ReferenceEquals(page, requestedContent)) return;
        requestedContent = page;
        // First presentation and reduced-motion navigation are immediate.
        if (!IsLoaded || displayedContent is null || !navigationUiSettings.AnimationsEnabled
            || ReferenceEquals(page, displayedContent))
        {
            ResetContentTransition();
            PresentContent(page);
            return;
        }
        // Coalesce rapid selections during exit. Never queue animations for obsolete pages.
        if (contentExiting) return;
        ResetContentTransition();
        contentExiting = true;
        AnimateContent(entering: false, () =>
        {
            PresentContent(requestedContent!);
            if (IsLoaded && navigationUiSettings.AnimationsEnabled)
                AnimateContent(entering: true, () => { });
            else
                ResetContentTransition();
        });
    }

    private void PresentContent(FrameworkElement page, bool refresh = true)
    {
        if (refresh && page == SettingsRoot) SettingsRoot.PrepareForNavigation();
        displayedContent = page;
        HomeRoot.Visibility = page == HomeRoot ? Visibility.Visible : Visibility.Collapsed;
        GameExtensionsRoot.Visibility = page == GameExtensionsRoot ? Visibility.Visible : Visibility.Collapsed;
        SettingsRoot.Visibility = page == SettingsRoot ? Visibility.Visible : Visibility.Collapsed;
        LogsRoot.Visibility = page == LogsRoot ? Visibility.Visible : Visibility.Collapsed;
        // Preserve realized save rows, selection bars and scroll offsets. Do not replace
        // this with Frame.Navigate or collapse SavesRoot to implement the transition.
        var saves = page == SavesRoot;
        SavesRoot.Opacity = saves ? 1 : 0;
        SavesRoot.IsHitTestVisible = saves;
        if (refresh && page == SettingsRoot) SettingsRoot.CompleteInitialLayout();
        if (refresh && page == GameExtensionsRoot) _ = GameExtensionsRoot.RefreshForNavigationAsync();
        if (refresh && page == LogsRoot) LogsRoot.RefreshForNavigation();
    }

    private void AnimateContent(bool entering, Action completed)
    {
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        contentTransitionCompleted = completed;
        contentTransitionBatch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        contentTransitionBatch.Completed += ContentTransition_Completed;
        // Animate only the content host, not the navigation rail, footer or title bar.
        // There is no layout animation, per-frame callback, timer or page reconstruction.
        PageContent.IsHitTestVisible = false;
        // Keep the base values at the animation's destination, so completion cannot
        // reveal the old page while its dispatcher callback is still queued.
        PageContent.Opacity = entering ? 1 : 0;
        PageContent.Translation = Vector3.Zero;
        contentFade = compositor.CreateScalarKeyFrameAnimation();
        contentFade.Target = "Opacity";
        contentFade.InsertKeyFrame(0, entering ? 0 : 1);
        contentFade.InsertKeyFrame(1, entering ? 1 : 0, compositor.CreateLinearEasingFunction());
        contentFade.Duration = TimeSpan.FromMilliseconds(entering ? 167 : 83);
        PageContent.StartAnimation(contentFade);
        if (entering)
        {
            contentRise = compositor.CreateVector3KeyFrameAnimation();
            contentRise.Target = "Translation";
            contentRise.InsertKeyFrame(0, new Vector3(0, 20, 0));
            contentRise.InsertKeyFrame(1, Vector3.Zero,
                compositor.CreateCubicBezierEasingFunction(Vector2.Zero, new Vector2(0, 1)));
            contentRise.Duration = TimeSpan.FromMilliseconds(250);
            PageContent.StartAnimation(contentRise);
        }
        contentTransitionBatch.End();
    }

    private void ContentTransition_Completed(object sender, CompositionBatchCompletedEventArgs args)
    {
        // A stopped animation may already have queued its completion. Only the current
        // batch can change pages, and all XAML work stays on the UI dispatcher.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!ReferenceEquals(sender, contentTransitionBatch)) return;
            var completed = contentTransitionCompleted;
            // The outgoing page stays hidden while the incoming page creates its
            // templates, loads settings and completes its first layout.
            ResetContentTransition(restorePresentation: !contentExiting);
            completed?.Invoke();
        });
    }

    private void ResetContentTransition(bool restorePresentation = true)
    {
        if (contentTransitionBatch is { } batch)
        {
            contentTransitionBatch = null;
            batch.Completed -= ContentTransition_Completed;
            batch.Dispose();
        }
        contentTransitionCompleted = null;
        contentExiting = false;
        if (contentFade is not null) { PageContent.StopAnimation(contentFade); contentFade.Dispose(); contentFade = null; }
        if (contentRise is not null) { PageContent.StopAnimation(contentRise); contentRise.Dispose(); contentRise = null; }
        if (restorePresentation)
        {
            PageContent.Opacity = 1;
            PageContent.Translation = Vector3.Zero;
            PageContent.IsHitTestVisible = true;
        }
    }

    private void FinishContentNavigation()
    {
        ResetContentTransition();
        // Unloading cannot leave the selected page transparent or commit an old completion
        // after the shell is shown again. Do not start background refreshes while unloading.
        if (requestedContent is { } page) PresentContent(page, refresh: false);
    }
}
