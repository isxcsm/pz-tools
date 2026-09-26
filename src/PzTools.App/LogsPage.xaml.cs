using System.Collections.ObjectModel;
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PzTools.Projections;
using Windows.ApplicationModel.DataTransfer;

namespace PzTools.App;

public sealed partial class LogsPage : UserControl
{
    private const int LogArrivalDurationMs = 420;
    private const int LogArrivalRisePx = 10;
    private IReadOnlyList<LogEntryView> source = [];
    private bool levelChosenByUser;
    private readonly ObservableCollection<LogEntryUiItem> displayedItems = [];
    private int unreadIssues;
    private bool hasLoadedLogs;
    private bool loadFailed;
    private int pageIndex;
    private int totalGroups;
    private long pageSnapshot;
    private long liveLatestIndex;
    private long queryVersion;
    private int renderedPagerPageIndex = -1;
    private int renderedPagerPages = -1;
    private CancellationTokenSource? pageQueryCancellation;
    private readonly AnimatedListSelectionBar logSelectionBar;
    private readonly Dictionary<ListViewItem, (ScalarKeyFrameAnimation Fade,
        Vector3KeyFrameAnimation Rise)> logArrivalAnimations = [];

    public LogsPage()
    {
        InitializeComponent();
        LogList.ItemsSource = displayedItems;
        logSelectionBar = new AnimatedListSelectionBar(
            LogList, LogSelectionLayer, LogSelectionBar, 7);
        ApplyLocalizedText();
        Loaded += (_, _) => { LoadOptions(); _ = LoadPageAsync(resetSnapshot: true); };
        Unloaded += (_, _) => { ResetLogArrivalAnimations(); CloseFiltersAndQueries(); };
    }

    private App App => (App)Application.Current;

    public void RefreshForNavigation()
    {
        if (!IsLoaded) return;
        LoadOptions();
        _ = LoadPageAsync(resetSnapshot: true, scrollToTop: false);
    }

    private void LoadOptions()
    {
        var settings = App.Host?.Views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot;
        if (settings is null) return;
        recordMinimum = Enum.Parse<LogLevel>(settings.LogRecordMinimumLevel);
        var desired = levelChosenByUser ? minimumLevel : LogLevel.Warning;
        minimumLevel = (LogLevel)Math.Max((int)desired, (int)recordMinimum);
        UpdateFilterChips();
        ApplyFilter();
    }

    private void LogsPage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var stacked = e.NewSize.Width < 902;
        LogListColumn.Width = new GridLength(stacked ? 1 : 3, GridUnitType.Star);
        LogDetailColumn.Width = new GridLength(stacked ? 0 : 2, GridUnitType.Star);
        LogDetailRow.Height = new GridLength(stacked ? 1 : 0, GridUnitType.Star);
        Grid.SetColumn(LogDetailCard, stacked ? 0 : 1);
        Grid.SetRow(LogDetailCard, stacked ? 1 : 0);
    }

    public void Apply(LogsView view)
    {
        unreadIssues = view.UnreadIssues;
        AcknowledgeAllButton.Visibility = unreadIssues > 0
            ? Visibility.Visible : Visibility.Collapsed;
        AcknowledgeAllButton.Content = Localizer.Format("AcknowledgeAllLogsFormat", unreadIssues);
        EmptyLogsText.Text = Localizer.Get("NoLogs");
        var latest = view.Entries.Count == 0 ? 0 : view.Entries.Max(item => item.LogIndex);
        if (!hasLoadedLogs && !loadFailed && pageQueryCancellation is null)
            _ = LoadPageAsync(resetSnapshot: true);
        if (latest != liveLatestIndex)
        {
            liveLatestIndex = latest;
            if (hasLoadedLogs && pageIndex == 0)
                _ = LoadPageAsync(resetSnapshot: true, scrollToTop: false,
                    animateNewRows: true);
        }
    }

    public void ShowLoadFailure()
    {
        if (hasLoadedLogs) return;
        loadFailed = true;
        EmptyLogsText.Text = Localizer.Get("LogsUnavailable");
        ApplyFilter();
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        TitleText.Text = Localizer.Get("LogsTitle");
        AppToolTip.SetTip(NewerPageButton, Localizer.Get("LogPreviousPage"));
        AppToolTip.SetTip(OlderPageButton, Localizer.Get("LogNextPage"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(NewerPageButton, Localizer.Get("LogPreviousPage"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(OlderPageButton, Localizer.Get("LogNextPage"));
        LoadingLogsText.Text = Localizer.Get("LoadingLogs");
        EmptyLogsText.Text = Localizer.Get(loadFailed ? "LogsUnavailable" : "NoLogs");
        AcknowledgeAllButton.Content = Localizer.Format("AcknowledgeAllLogsFormat", unreadIssues);
        AcknowledgeSelectedButton.Content = Localizer.Get("AcknowledgeIssue");
        var copyLabel = Localizer.Get("CopyLogDetails");
        AppToolTip.SetTip(CopyLogDetailsButton, copyLabel);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(CopyLogDetailsButton, copyLabel);
        LocalizeFilterHeaders();
        RelatedLogsTitle.Text = Localizer.Get("RelatedLogsTitle");
        TechnicalDetailsExpander.Header = Localizer.Get("TechnicalDetails");
        SelectLogText.Text = Localizer.Get("SelectLog");
        DetailTimeLabel.Text = Localizer.Get("Time");
        DetailComponentLabel.Text = Localizer.Get("LogComponentFilter");
        DetailRunLabel.Text = Localizer.Get("LogRunIndexFilter");
        DetailEventLabel.Text = Localizer.Get("LogEventCode");
        DetailSourceLabel.Text = Localizer.Get("LogSource");
        DetailEventIdLabel.Text = Localizer.Get("LogEventId");
        DetailInstanceLabel.Text = Localizer.Get("LogInstanceId");
        DetailFailureCodeLabel.Text = Localizer.Get("LogDiagnostics.Code");
        DetailPayloadLabel.Text = Localizer.Get("RawLogPayload");
        NoPayloadText.Text = Localizer.Get("NoPayload");
        DiagnosticsTitle.Text = Localizer.Get("LogDiagnostics.Title");
        ApplyFilter(refreshLocalizedText: true);
    }

    private async Task LoadPageAsync(bool resetSnapshot, bool scrollToTop = true,
        bool animateNewRows = false)
    {
        var inbox = App.Host?.LogInbox;
        if (inbox is null || !IsLoaded) return;
        var version = ++queryVersion;
        pageQueryCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        pageQueryCancellation = cancellation;
        var requestedPage = resetSnapshot ? 0 : pageIndex;
        var snapshot = resetSnapshot ? 0 : pageSnapshot;
        if (!hasLoadedLogs) ApplyFilter();
        try
        {
            var query = new LogPageQuery(minimumLevel, componentCategory,
                runRange?.ToString() ?? "", requestedPage, 100, snapshot,
                logRange?.ToString() ?? "", timeRange?.FromUtc, timeRange?.ThroughUtc);
            var result = await Task.Run(() => inbox.ReadPageAsync(query, cancellation.Token),
                cancellation.Token);
            if (version != queryVersion) return;
            pageSnapshot = result.SnapshotMaxLogIndex;
            totalGroups = result.TotalGroups;
            pageIndex = requestedPage;
            if (totalGroups > 0 && result.Entries.Count == 0 && pageIndex > 0)
            {
                pageIndex = Math.Max(0, (totalGroups - 1) / 100);
                await LoadPageAsync(resetSnapshot: false, scrollToTop);
                return;
            }
            source = result.Entries;
            hasLoadedLogs = true;
            loadFailed = false;
            ApplyFilter(animateNewRows: animateNewRows);
            if (scrollToTop && displayedItems.Count > 0)
                LogList.ScrollIntoView(displayedItems[0], ScrollIntoViewAlignment.Leading);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception exception)
        {
            if (version != queryVersion) return;
            if (!hasLoadedLogs) ShowLoadFailure();
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("LogsNavigation.Content"), UserFacingError.FromException(exception));
        }
        finally
        {
            if (ReferenceEquals(pageQueryCancellation, cancellation)) pageQueryCancellation = null;
            cancellation.Dispose();
        }
    }

    private void UpdatePageControls(bool force = false)
    {
        var pages = Math.Max(1, (totalGroups + 99) / 100);
        PagerFooter.Visibility = hasLoadedLogs && totalGroups > 0
            ? Visibility.Visible : Visibility.Collapsed;
        PagerNavigation.Visibility = pages > 1
            ? Visibility.Visible : Visibility.Collapsed;
        NewerPageButton.IsEnabled = hasLoadedLogs && pageIndex > 0;
        OlderPageButton.IsEnabled = hasLoadedLogs && pageIndex + 1 < pages;
        if (!hasLoadedLogs || (!force && renderedPagerPageIndex == pageIndex
            && renderedPagerPages == pages)) return;
        renderedPagerPageIndex = pageIndex;
        renderedPagerPages = pages;
        PageNumberButtons.Children.Clear();
        var visible = new SortedSet<int> { 0, pages - 1 };
        if (pages <= 8)
        {
            for (var number = 0; number < pages; number++) visible.Add(number);
        }
        else if (pageIndex <= 3)
        {
            for (var number = 0; number <= 3; number++) visible.Add(number);
        }
        else if (pageIndex >= pages - 4)
        {
            for (var number = pages - 4; number < pages; number++) visible.Add(number);
        }
        else
        {
            for (var number = pageIndex - 1; number <= pageIndex + 1; number++)
                visible.Add(number);
        }
        var previous = -1;
        foreach (var number in visible)
        {
            if (previous >= 0 && number - previous > 1)
            {
                var gapButton = new Button
                {
                    Content = "…",
                    Style = (Style)Resources["LogPageButtonStyle"],
                };
                AppToolTip.SetTip(gapButton, Localizer.Get("LogJumpToPage"));
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(gapButton,
                    Localizer.Get("LogJumpToPage"));
                gapButton.Click += PageGapButton_Click;
                PageNumberButtons.Children.Add(gapButton);
            }
            var button = new Button
            {
                Content = (number + 1).ToString(Localizer.Culture),
                Tag = number,
                Style = (Style)Resources[number == pageIndex
                    ? "SelectedLogPageButtonStyle" : "LogPageButtonStyle"],
            };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button,
                Localizer.Format(number == pageIndex
                    ? "LogCurrentPageFormat" : "LogGoToPageFormat", number + 1));
            button.Click += PageNumberButton_Click;
            PageNumberButtons.Children.Add(button);
            previous = number;
        }
    }

    private void PageGapButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement anchor) return;
        var pages = Math.Max(1, (totalGroups + 99) / 100);
        var pageNumber = new NumberBox
        {
            Header = Localizer.Get("LogJumpPageHeader"),
            PlaceholderText = Localizer.Format("LogJumpPagePlaceholder", pages),
            Value = double.NaN,
        };
        var validationText = new TextBlock
        {
            Text = Localizer.Format("LogJumpPageInvalid", pages),
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Visibility = Visibility.Collapsed,
        };
        var confirmButton = new Button
        {
            Content = Localizer.Get("LogJumpPageConfirm"),
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var content = new StackPanel { Width = 200, Spacing = 8 };
        content.Children.Add(pageNumber);
        content.Children.Add(validationText);
        content.Children.Add(confirmButton);
        var flyout = new Flyout { Content = content };
        var navigating = false;

        async Task JumpAsync()
        {
            if (navigating) return;
            if (!int.TryParse(pageNumber.Text.Trim(),
                    NumberStyles.Integer | NumberStyles.AllowThousands,
                    Localizer.Culture, out var target)
                || target < 1 || target > pages)
            {
                validationText.Visibility = Visibility.Visible;
                pageNumber.Focus(FocusState.Programmatic);
                return;
            }

            navigating = true;
            flyout.Hide();
            if (target - 1 == pageIndex) return;
            pageIndex = target - 1;
            await LoadPageAsync(resetSnapshot: false);
        }

        confirmButton.Click += async (_, _) => await JumpAsync();
        pageNumber.AddHandler(UIElement.KeyDownEvent,
            new KeyEventHandler(async (_, args) =>
            {
                if (args.Key != Windows.System.VirtualKey.Enter) return;
                args.Handled = true;
                await JumpAsync();
            }), true);
        flyout.Opened += (_, _) => pageNumber.Focus(FocusState.Programmatic);
        flyout.ShowAt(anchor);
    }

    private async void PageNumberButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: int target } || target == pageIndex) return;
        pageIndex = target;
        await LoadPageAsync(resetSnapshot: false);
    }

    private async void NewerPageButton_Click(object sender, RoutedEventArgs e)
    {
        if (pageIndex <= 0) return;
        pageIndex--;
        await LoadPageAsync(resetSnapshot: false);
    }

    private async void OlderPageButton_Click(object sender, RoutedEventArgs e)
    {
        if (pageIndex + 1 >= (totalGroups + 99) / 100) return;
        pageIndex++;
        await LoadPageAsync(resetSnapshot: false);
    }

    private void ApplyFilter(bool refreshLocalizedText = false, bool animateNewRows = false)
    {
        var selectedId = (LogList?.SelectedItem as LogEntryUiItem)?.EntryId;
        var desired = LogDisplayGrouping.Group(source)
            .Select(group => new LogEntryUiItem(group))
            .ToArray();
        var newRows = SyncDisplayedItems(desired, refreshLocalizedText);

        LoadingLogs.Visibility = hasLoadedLogs || loadFailed
            ? Visibility.Collapsed : Visibility.Visible;
        EmptyLogs.Visibility = loadFailed || (hasLoadedLogs && displayedItems.Count == 0)
            ? Visibility.Visible : Visibility.Collapsed;
        var first = totalGroups == 0 || displayedItems.Count == 0 ? 0 : pageIndex * 100 + 1;
        var last = first == 0 ? 0 : first + displayedItems.Count - 1;
        PageRangeSummaryText.Text = first == 0
            ? Localizer.Format("LogGroupCountFormat", totalGroups)
            : Localizer.Format("LogPageRangeSummaryFormat", totalGroups, first, last);
        UpdatePageControls(refreshLocalizedText);
        if (selectedId is not null && LogList is not null)
        {
            var selected = displayedItems.FirstOrDefault(item => item.EntryId == selectedId);
            if (!ReferenceEquals(LogList.SelectedItem, selected)) LogList.SelectedItem = selected;
        }
        if (animateNewRows && newRows.Count > 0) AnimateNewLogRows(newRows);
    }

    private IReadOnlyList<LogEntryUiItem> SyncDisplayedItems(LogEntryUiItem[] desired,
        bool forceReplace)
    {
        if (!forceReplace && desired.Length == displayedItems.Count
            && desired.Select((item, index) =>
                item.HasSamePresentation(displayedItems[index])).All(same => same))
            return [];

        ResetLogArrivalAnimations();
        // 새 로그는 최신순 목록 앞에 붙습니다. 기존 행을 유지하면 ListView가
        // ItemsSource 전체를 다시 구성하지 않아 선택 상태와 화면이 깜빡이지 않습니다.
        if (!forceReplace && displayedItems.Count > 0)
        {
            var shift = Array.FindIndex(desired,
                item => item.EntryId == displayedItems[0].EntryId);
            var overlap = desired.Length - shift;
            if (shift is >= 0 and <= 16 && displayedItems.Count >= overlap
                && Enumerable.Range(0, overlap).All(index =>
                    displayedItems[index].EntryId == desired[index + shift].EntryId))
            {
                while (displayedItems.Count > overlap)
                    displayedItems.RemoveAt(displayedItems.Count - 1);
                for (var index = 0; index < shift; index++)
                    displayedItems.Insert(index, desired[index]);
                for (var index = shift; index < desired.Length; index++)
                    if (!desired[index].HasSamePresentation(displayedItems[index]))
                        displayedItems[index] = desired[index];
                return shift > 0 ? desired[..shift] : [];
            }
        }

        while (displayedItems.Count > desired.Length)
            displayedItems.RemoveAt(displayedItems.Count - 1);
        for (var index = 0; index < desired.Length; index++)
        {
            if (index == displayedItems.Count) displayedItems.Add(desired[index]);
            else if (forceReplace || !desired[index].HasSamePresentation(displayedItems[index]))
                displayedItems[index] = desired[index];
        }
        return [];
    }

    private void ResetLogArrivalAnimations()
    {
        foreach (var (container, animations) in logArrivalAnimations)
        {
            container.StopAnimation(animations.Fade);
            container.StopAnimation(animations.Rise);
            container.Opacity = 1;
            container.Translation = Vector3.Zero;
        }
        logArrivalAnimations.Clear();
    }

    private void AnimateNewLogRows(IReadOnlyList<LogEntryUiItem> newRows)
    {
        LogList.UpdateLayout();
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var easing = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.2f, 0f), new Vector2(0f, 1f));
        foreach (var row in newRows)
        {
            if (LogList.ContainerFromItem(row) is not ListViewItem container
                || container.ActualHeight <= 0) continue;
            var position = container.TransformToVisual(LogList)
                .TransformPoint(new Windows.Foundation.Point(0, 0));
            if (position.Y + container.ActualHeight <= 0
                || position.Y >= LogList.ActualHeight) continue;

            var fade = compositor.CreateScalarKeyFrameAnimation();
            fade.Target = "Opacity";
            fade.InsertKeyFrame(0f, 0.35f);
            fade.InsertKeyFrame(1f, 1f, easing);
            fade.Duration = TimeSpan.FromMilliseconds(LogArrivalDurationMs);

            var rise = compositor.CreateVector3KeyFrameAnimation();
            rise.Target = "Translation";
            rise.InsertKeyFrame(0f, new Vector3(0, LogArrivalRisePx, 0));
            rise.InsertKeyFrame(1f, Vector3.Zero, easing);
            rise.Duration = fade.Duration;

            container.Opacity = 1;
            container.Translation = Vector3.Zero;
            container.StartAnimation(fade);
            container.StartAnimation(rise);
            logArrivalAnimations.Add(container, (fade, rise));
        }
    }

    private void LogList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LogList.SelectedItem is not LogEntryUiItem item)
        {
            NoLogSelectedCard.Visibility = Visibility.Visible;
            LogDetail.Visibility = Visibility.Collapsed;
            AcknowledgeSelectedButton.Visibility = Visibility.Collapsed;
            return;
        }
        NoLogSelectedCard.Visibility = Visibility.Collapsed;
        LogDetail.Visibility = Visibility.Visible;
        DetailLogIndex.Text = Localizer.Format("LogIndexFormat", item.LogIndexText);
        AcknowledgeSelectedButton.Visibility = item.IsUnread
            ? Visibility.Visible : Visibility.Collapsed;
        AcknowledgeSelectedButton.Content = Localizer.Get(item.RunIndex > 0
            ? "AcknowledgeIssue" : "AcknowledgeAlert");
        DetailMessage.Text = item.Message;
        DetailSummaryTime.Text = Localizer.Format("LogSummaryFormat", item.TimeText, item.Component);
        DetailTime.Text = item.TimeText;
        DetailComponent.Text = item.Component;
        DetailRun.Text = item.RunIndex.ToString(Localizer.Culture);
        DetailEvent.Text = item.EventName;
        DetailSource.Text = item.SourceId;
        DetailEventId.Text = item.EventId.ToString(Localizer.Culture);
        DetailInstance.Text = item.TelemetryInstanceId.ToString("D");
        DetailFailureCode.Text = item.Diagnostics?.FailureCode ?? "—";
        ShowDiagnostics(item.Diagnostics);
        ShowRelatedLogs(item);
        var hasPayload = item.RelatedEntries.Any(entry =>
            !string.IsNullOrWhiteSpace(entry.PayloadJson));
        NoPayloadText.Visibility = hasPayload ? Visibility.Collapsed : Visibility.Visible;
        DetailPayload.Visibility = hasPayload ? Visibility.Visible : Visibility.Collapsed;
        DetailPayload.Text = !hasPayload ? string.Empty
            : item.RelatedEntries.Count > 1
                ? FormatRelatedPayloads(item.RelatedEntries)
                : FormatPayload(item.PayloadJson);
    }

    private void CopyLogDetailsButton_Click(object sender, RoutedEventArgs e)
    {
        if (LogList.SelectedItem is not LogEntryUiItem item) return;
        var text = new StringBuilder();
        text.AppendLine(DetailLogIndex.Text);
        text.AppendLine($"{LogMessageHeader.Text}: {DetailMessage.Text}");
        text.AppendLine($"{LogLevelHeader.Text}: {item.LevelText}");
        text.AppendLine($"{DetailTimeLabel.Text}: {DetailTime.Text}");
        text.AppendLine($"{DetailComponentLabel.Text}: {DetailComponent.Text}");
        if (item.RunIndex > 0)
            text.AppendLine($"{DetailRunLabel.Text}: {DetailRun.Text}");

        if (DiagnosticsCard.Visibility == Visibility.Visible)
        {
            text.AppendLine().AppendLine(DiagnosticsTitle.Text);
            foreach (var row in DiagnosticsFields.Children.OfType<Grid>())
            {
                var fields = row.Children.OfType<TextBlock>().ToArray();
                if (fields.Length >= 2)
                    text.AppendLine($"{fields[0].Text}: {fields[1].Text}");
            }
        }
        if (RelatedLogsCard.Visibility == Visibility.Visible)
        {
            text.AppendLine().AppendLine(RelatedLogsTitle.Text);
            foreach (var line in RelatedLogsPanel.Children.OfType<TextBlock>())
                text.AppendLine(line.Text);
        }

        text.AppendLine().AppendLine(TechnicalDetailsExpander.Header?.ToString());
        text.AppendLine($"{DetailEventLabel.Text}: {DetailEvent.Text}");
        text.AppendLine($"{DetailSourceLabel.Text}: {DetailSource.Text}");
        text.AppendLine($"{DetailEventIdLabel.Text}: {DetailEventId.Text}");
        text.AppendLine($"{DetailInstanceLabel.Text}: {DetailInstance.Text}");
        if (item.Diagnostics?.FailureCode is not null)
            text.AppendLine($"{DetailFailureCodeLabel.Text}: {DetailFailureCode.Text}");
        if (DetailPayload.Visibility == Visibility.Visible)
            text.AppendLine().AppendLine(DetailPayloadLabel.Text).AppendLine(DetailPayload.Text);

        try
        {
            var package = new DataPackage();
            package.SetText(text.ToString().TrimEnd());
            Clipboard.SetContent(package);
            App.ShowSidebarNotification(InfoBarSeverity.Success,
                Localizer.Get("LogsNavigation.Content"), Localizer.Get("LogDetailsCopied"));
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("LogsNavigation.Content"), UserFacingError.FromException(exception));
        }
    }

    private async void AcknowledgeSelectedButton_Click(object sender, RoutedEventArgs e)
    {
        if (LogList.SelectedItem is not LogEntryUiItem { IsUnread: true,
                IncidentKey: not null } item || App.Host is not { } host) return;
        AcknowledgeSelectedButton.IsEnabled = false;
        try
        {
            Apply(await host.AcknowledgeLogIssueAsync(item.IncidentKey));
            await LoadPageAsync(resetSnapshot: false);
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("LogsNavigation.Content"), UserFacingError.FromException(exception));
        }
        finally { AcknowledgeSelectedButton.IsEnabled = true; }
    }

    private async void AcknowledgeAllButton_Click(object sender, RoutedEventArgs e)
    {
        if (unreadIssues == 0 || App.Host is not { } host) return;
        AcknowledgeAllButton.IsEnabled = false;
        try
        {
            Apply(await host.AcknowledgeAllLogIssuesAsync());
            await LoadPageAsync(resetSnapshot: false);
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("LogsNavigation.Content"), UserFacingError.FromException(exception));
        }
        finally { AcknowledgeAllButton.IsEnabled = true; }
    }

    private void ShowDiagnostics(LogDiagnostics? diagnostics)
    {
        DiagnosticsFields.Children.Clear();
        if (diagnostics is null)
        {
            DiagnosticsCard.Visibility = Visibility.Collapsed;
            return;
        }

        AddDiagnostic("Save", diagnostics.SaveId);
        AddDiagnostic("Path", diagnostics.Path);
        AddDiagnostic("Reason", UserFacingReason(diagnostics));
        AddDiagnostic("Phase", diagnostics.Phase is { } phase ? LocalizedPhase(phase) : null);
        AddDiagnostic("FailedFileCount", diagnostics.FailedFileCount);
        AddDiagnostic("FailedFiles", diagnostics.FailedFiles);
        if (!string.Equals(diagnostics.Message, diagnostics.Reason, StringComparison.Ordinal))
            AddDiagnostic("Message", diagnostics.Message);
        if (DiagnosticsFields.Children.Count == 0 && diagnostics.FailureCode is not null)
            AddDiagnostic("Reason", Localizer.Get("LogDiagnostics.LegacyMissingDetail"));
        DiagnosticsCard.Visibility = DiagnosticsFields.Children.Count > 0
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string? UserFacingReason(LogDiagnostics diagnostics) => diagnostics.Reason switch
    {
        "copy differs from both source reads" => Localizer.Get("LogDiagnostics.FileChanged"),
        "file access failed" => Localizer.Get("LogDiagnostics.FileAccessFailed"),
        "was renamed, deleted, or replaced" or "was replaced while opening"
            or "was replaced while rechecking" => Localizer.Get("LogDiagnostics.FileReplaced"),
        "copy length changed" => Localizer.Get("LogDiagnostics.FileChanged"),
        null when diagnostics.FailureCode == "UnstableFileException" =>
            Localizer.Get("LogDiagnostics.UnstableFileHint"),
        var reason => reason,
    };

    private void ShowRelatedLogs(LogEntryUiItem item)
    {
        RelatedLogsPanel.Children.Clear();
        RelatedLogsCard.Visibility = item.RelatedEntries.Count > 1
            ? Visibility.Visible : Visibility.Collapsed;
        if (item.RelatedEntries.Count <= 1) return;
        RelatedLogsTitle.Text = Localizer.Format("RelatedLogCountFormat", item.RelatedEntries.Count);
        foreach (var entry in item.RelatedEntries.OrderByDescending(value => value.OccurredUtc)
                     .Take(12).OrderBy(value => value.OccurredUtc))
        {
            var related = new LogEntryUiItem(entry);
            RelatedLogsPanel.Children.Add(new TextBlock
            {
                Text = Localizer.Format("RelatedLogLineFormat",
                    related.LogIndexText, related.ShortTimeText, related.Message),
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
        }
        if (item.RelatedEntries.Count > 12)
            RelatedLogsPanel.Children.Add(new TextBlock
            {
                Text = Localizer.Format("RelatedLogsMoreFormat", item.RelatedEntries.Count - 12),
                Opacity = 0.62,
                IsTextSelectionEnabled = true,
            });
    }

    private void AddDiagnostic(string key, string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var label = new TextBlock { Text = Localizer.Get($"LogDiagnostics.{key}"), Opacity = 0.62,
            MinWidth = 88, IsTextSelectionEnabled = true };
        var content = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true };
        Grid.SetColumn(content, 1);
        row.Children.Add(label);
        row.Children.Add(content);
        DiagnosticsFields.Children.Add(row);
    }

    private static string LocalizedPhase(string phase) => phase switch
    {
        "boundary" or "scan" or "hash" or "planning" or "capture" or "pack" or "commit"
            or "restore" or "source.prepare" or "deduplication" => Localizer.Get($"LogPhase.{phase}"),
        "copy" => Localizer.Get("BackupCopyPhase"),
        "copy.retry" => Localizer.Get("BackupCopyRetryPhase"),
        "archive.snapshot" => Localizer.Get("ArchiveSnapshotPhase"),
        "archive.restore" => Localizer.Get("ArchiveRestorePhase"),
        "archive.compress" => Localizer.Get("ArchiveCompressPhase"),
        "archive.finalize" => Localizer.Get("ArchiveFinalizePhase"),
        "import" => Localizer.Get("Importing"),
        _ => phase,
    };

    private static string FormatPayload(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return string.Empty;
        try
        {
            using var document = JsonDocument.Parse(json);
            return JsonSerializer.Serialize(document.RootElement, new JsonSerializerOptions
            {
                WriteIndented = true,
            });
        }
        catch (JsonException) { return json; }
    }

    private static string FormatRelatedPayloads(IReadOnlyList<LogEntryView> entries) =>
        JsonSerializer.Serialize(entries.OrderBy(item => item.OccurredUtc).Select(item => new
        {
            logIndex = item.LogIndex,
            timeLocal = item.OccurredUtc.ToLocalTime().ToString("O"),
            eventCode = item.EventName,
            payload = ParsePayload(item.PayloadJson),
        }), new JsonSerializerOptions { WriteIndented = true });

    private static object? ParsePayload(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try { return JsonNode.Parse(json); }
        catch (JsonException) { return json; }
    }
}

public sealed class LogEntryUiItem
{
    private readonly LogDisplayGroup group;
    private readonly LogEntryView model;
    private readonly LogActivityContext activity;
    private readonly string? outcome;
    private LogDiagnostics? diagnostics;
    private bool diagnosticsParsed;

    public LogEntryUiItem(LogDisplayGroup group)
    {
        this.group = group;
        model = group.Primary;
        activity = LogActivityContext.From(model);
        outcome = LogDiagnostics.ReadOutcome(model.PayloadJson);
    }

    public LogEntryUiItem(LogEntryView model)
        : this(LogDisplayGrouping.Group([model])[0]) { }

    public IReadOnlyList<LogEntryView> RelatedEntries => group.Entries;
    public string EntryId => group.Key;
    public long LogIndex => model.LogIndex;
    public string LogIndexText => model.LogIndex > 0 ? $"#{model.LogIndex}" : "—";
    public string? IncidentKey => model.IncidentKey;
    public bool IsUnread => group.IsUnread;
    public Visibility UnreadVisibility => IsUnread ? Visibility.Visible : Visibility.Collapsed;
    public string SourceId => model.SourceId;
    public Guid TelemetryInstanceId => model.TelemetryInstanceId;
    public long EventId => model.EventId;
    public DateTimeOffset OccurredUtc => group.LatestUtc;
    public string TimeText => LogTimeFormatter.FormatFull(OccurredUtc);
    public string ShortTimeText => LogTimeFormatter.FormatShort(OccurredUtc);
    public string LevelText => Localizer.Get($"LogLevel.{group.Level}");
    public Brush LevelBrush => new SolidColorBrush(group.Level switch
    {
        LogLevel.Trace => Colors.Gray,
        LogLevel.Information => Colors.DodgerBlue,
        LogLevel.Warning => Colors.DarkOrange,
        LogLevel.Error => Colors.OrangeRed,
        LogLevel.Critical => Colors.Crimson,
        _ => Colors.Gray,
    });
    public string Component => activity.Kind is LogActivityKind.ArchiveExport
        or LogActivityKind.ArchiveImport or LogActivityKind.ArchiveInspect or LogActivityKind.CharacterRecovery
        ? ActivityName : Localizer.Get($"LogComponent.{ComponentCategory(model.Component)}");
    public static string ComponentCategory(string component) => component switch
    {
        "backup-worker" or "backup-runner" => "Backup",
        "restore-worker" => "Restore",
        var restore when restore.StartsWith("restore-", StringComparison.Ordinal) => "Restore",
        "archive-worker" => "Archive",
        var archive when archive.StartsWith("archive-", StringComparison.Ordinal) => "Archive",
        "state-runner" or "state-collector" or "state-reactor" or "state-scheduler" =>
            "State",
        "backup-scheduler" => "Schedule",
        "maintenance-worker" or "maintenance-runner" => "Maintenance",
        var lane when lane.StartsWith("maintenance-lane-", StringComparison.Ordinal) => "Maintenance",
        _ => "Other",
    };
    public long RunIndex => model.RunIndex;
    public string RunIndexFullText => model.RunIndex > 0 ? $"#{model.RunIndex}" : "—";
    public string RunIndexText => model.RunIndex <= 0 ? "—"
        : model.RunIndex.ToString() is var number && number.Length > 8
            ? $"#…{number[^6..]}" : $"#{number}";
    public string EventName => model.EventName;
    public bool HasSamePresentation(LogEntryUiItem other) =>
        EntryId == other.EntryId
        && model.EntryId == other.model.EntryId
        && model.PayloadJson == other.model.PayloadJson
        && group.LatestUtc == other.group.LatestUtc
        && group.Level == other.group.Level
        && group.IsUnread == other.group.IsUnread
        && group.Entries.Count == other.group.Entries.Count
        && group.Entries.Zip(other.group.Entries).All(pair =>
            pair.First.EntryId == pair.Second.EntryId
            && pair.First.PayloadJson == pair.Second.PayloadJson
            && pair.First.IsAcknowledged == pair.Second.IsAcknowledged);
    internal LogDiagnostics? Diagnostics
    {
        get
        {
            if (!diagnosticsParsed)
            {
                diagnostics = LogDiagnostics.Parse(model.PayloadJson);
                var relatedSave = group.Entries.Select(item => LogDiagnostics.Parse(item.PayloadJson))
                    .FirstOrDefault(item => item?.SaveId is not null)?.SaveId;
                if (diagnostics is not null && diagnostics.SaveId is null && relatedSave is not null)
                    diagnostics = diagnostics with { SaveId = relatedSave };
                diagnosticsParsed = true;
            }
            return diagnostics;
        }
    }
    private string ActivityName => Localizer.Get($"LogActivity.{activity.Kind}");
    private string ActivityMessage(string key) => Localizer.Format(key, ActivityName);
    public string Message => model.EventName switch
    {
        "extension.runtime.changed" when model.Level >= LogLevel.Warning =>
            Localizer.Format("LogEvent.RunFailed", Localizer.Get("Extension.VehicleDrivetrain.Title")),
        "extension.runtime.changed" =>
            Localizer.Format("LogEvent.Other", Localizer.Get("Extension.VehicleDrivetrain.Title")),
        "tick.completed" when outcome == "Failed" => ActivityMessage("LogEvent.TickFailed"),
        "tick.failed" => ActivityMessage("LogEvent.TickFailed"),
        var name when name.EndsWith(".completed", StringComparison.Ordinal)
            && outcome is "Failed" or "Abandoned" => ActivityMessage("LogEvent.RunFailed"),
        var name when name.EndsWith(".completed", StringComparison.Ordinal)
            && outcome == "Degraded" => ActivityMessage("LogEvent.PartialFailure"),
        var name when name.EndsWith(".completed", StringComparison.Ordinal)
            && outcome == "Cancelled" => ActivityMessage("LogEvent.RunCancelled"),
        var name when name.EndsWith(".completed", StringComparison.Ordinal)
            && outcome == "Busy" => ActivityMessage("LogEvent.RunBusy"),
        var name when name.EndsWith(".completed", StringComparison.Ordinal)
            && model.Level >= LogLevel.Warning => ActivityMessage("LogEvent.Other"),
        "tick.completed" => ActivityMessage("LogEvent.TickCompleted"),
        "state-runner.completed" => Localizer.Get("LogEvent.StateRunCompleted"),
        "collector.completed" => Localizer.Get("LogEvent.CollectorCompleted"),
        "reactor.completed" => Localizer.Get("LogEvent.ReactorCompleted"),
        "scan.completed" => Localizer.Get("LogEvent.ScanCompleted"),
        "source.prepare.started" => Localizer.Get("LogEvent.GameSaveStarted"),
        "source.prepare.completed" when outcome == "saved" => Localizer.Get("LogEvent.GameSaveCompleted"),
        "source.prepare.completed" when outcome is "not-in-world" or "game-not-running" or "save-mismatch"
            => Localizer.Get("LogEvent.GameSaveSkipped"),
        "source.prepare.completed" => Localizer.Get("LogEvent.GameSaveChecked"),
        "changes.planned" when activity.ChangeCount is { } count =>
            Localizer.Format("LogEvent.BackupChangesPlannedFormat", count),
        "changes.planned" => Localizer.Get("LogEvent.BackupChangesPlanned"),
        "capture.completed" => Localizer.Get("LogEvent.CaptureCompleted"),
        "run.started" => ActivityMessage("LogEvent.RunStarted"),
        "run.committed" when activity.Kind == LogActivityKind.Backup
            && activity.Revision is { } revision =>
            Localizer.Format("LogEvent.BackupCommittedFormat", revision),
        "run.committed" => ActivityMessage("LogEvent.RunCommitted"),
        "run.no_changes" => ActivityMessage("LogEvent.RunNoChanges"),
        "run.failed" when Diagnostics?.FailureCode == "UnstableFileException" =>
            Localizer.Get("LogEvent.UnstableFile"),
        "run.failed" when Diagnostics?.Phase == "source.prepare" =>
            Localizer.Get("LogEvent.GameSaveFailed"),
        "run.failed" => ActivityMessage("LogEvent.RunFailed"),
        "run.cancelled" => ActivityMessage("LogEvent.RunCancelled"),
        var name when name.EndsWith(".cancelled", StringComparison.Ordinal) =>
            ActivityMessage("LogEvent.RunCancelled"),
        var name when name.EndsWith(".busy", StringComparison.Ordinal) =>
            ActivityMessage("LogEvent.RunBusy"),
        "maintenance.orphanbackups.completed" => Localizer.Get("LogEvent.OrphanBackupsCleaned"),
        "maintenance.orphanbackups.removed" => Localizer.Get("LogEvent.OrphanBackupsCleaned"),
        "maintenance.orphanbackups.failed" => Localizer.Get("LogEvent.OrphanBackupsFailed"),
        "maintenance.recovery.completed" => Localizer.Get("LogEvent.InterruptedOperationsRecovered"),
        "maintenance.recovery.failed" => Localizer.Get("LogEvent.InterruptedOperationsRecoveryFailed"),
        var name when name.EndsWith(".failed", StringComparison.Ordinal) =>
            ActivityMessage("LogEvent.RunFailed"),
        "telemetry.source.recovered" => Localizer.Get("LogEvent.TelemetryRecovered"),
        "telemetry.source.stale" => Localizer.Get("LogEvent.TelemetryStale"),
        "telemetry.source.unreadable" => Localizer.Get("LogEvent.TelemetryUnreadable"),
        "telemetry.source.unsupportedschema" => Localizer.Get("LogEvent.TelemetryUnsupported"),
        var name when name.EndsWith(".completed", StringComparison.Ordinal) =>
            ActivityMessage("LogEvent.RunCommitted"),
        _ => ActivityMessage("LogEvent.Other"),
    };
    public string? PayloadJson => model.PayloadJson;
}
