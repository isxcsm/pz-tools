using System.Numerics;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PzTools.App.Core;
using Microsoft.Windows.Storage.Pickers;
using PzTools.Profiling;
using Windows.Foundation;

namespace PzTools.App;

/// <summary>
/// Record the running game, then look at the result: a frame-time graph that zooms like a stock
/// chart, and for any dragged range (or one clicked frame) where the time went, grouped by who owns
/// the code: the game itself, each mod, the Java runtime.
/// </summary>
public sealed partial class ProfilerPage : UserControl
{
    // Narrower than this and a time range says little: one frame at 60 fps is about 16.7 ms.
    private const long MinimumSpan = 50_000;
    private const double SlowFrameMilliseconds = 1000.0 / 30;
    // The functions of one owner get a pane of their own, so it can list more of them than a card could.
    private const int RowsPerGroup = 30;
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromMilliseconds(500) };
    // Whether there is a game to record, checked while the page is open. -1 until the first check.
    private readonly DispatcherTimer gameClock = new() { Interval = TimeSpan.FromSeconds(2) };
    private int games = -1;
    private bool checkingGames;
    private readonly AnimatedListSelectionBar groupSelectionBar;
    private readonly AnimatedSelectorBarIndicator tabIndicator;
    private readonly Windows.UI.ViewManagement.UISettings uiSettings = new();
    private ProfileRecordingService? service;
    private ProfileRecording? recording;
    private string? loadedPath;
    private long viewStart, viewEnd;
    private long? selectionStart, selectionEnd;
    private bool selecting, panning, updatingList, updatingScroll;
    private double pressX;
    private long pressViewStart;
    private int loadVersion, analysisVersion;
    private double gripStartY, gripStartHeight;
    private bool resizingChart, updatingGroups;
    private ProfileRange? shown;
    // The summary above the graph as plain text, for a copy of the page; the line itself changes while hovering.
    private string rangeSummary = "";
    // A newly opened recording's bars rise from the baseline once, the first time the graph is drawn.
    private bool chartEntrance;
    private List<ResultGroup> luaGroups = [], javaGroups = [], listedGroups = [];
    // The owner picked in each tab; a new range keeps it when the owner is still there.
    private string? luaSelection, javaSelection;
    private App App => (App)Application.Current;

    public ProfilerPage()
    {
        InitializeComponent();
        groupSelectionBar = new AnimatedListSelectionBar(GroupList, GroupSelectionLayer, GroupSelectionBar, 12);
        tabIndicator = new AnimatedSelectorBarIndicator(ResultTabs, TabSelectionLayer, TabSelectionBar);
        ApplyLocalizedText();
        clock.Tick += (_, _) => UpdateSession();
        gameClock.Tick += (_, _) => _ = CheckGamesAsync();
        // The page stays loaded while another page is shown (the shell only collapses it), so the game
        // check runs only while it is visible: listing processes every two seconds for a hidden page,
        // all day in the tray, was waste.
        Loaded += (_, _) => { Attach(); FollowVisibility(); };
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => { if (IsLoaded) FollowVisibility(); });
        Unloaded += (_, _) =>
        {
            clock.Stop();
            gameClock.Stop();
            if (service is not null) service.Changed -= Session_Changed;
            service = null;
        };
        // Text and grid lines drawn in code hold the brush of the theme they were drawn in.
        ActualThemeChanged += (_, _) => { RenderChart(); if (shown is not null) ShowRange(shown); };
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        PageTitle.Text = Localizer.Get("ProfilerNavigation");
        ModeSwitch.OffContent = Localizer.Get("ProfileModeGeneral");
        ModeSwitch.OnContent = Localizer.Get("ProfileModeDetailed");
        AppToolTip.SetTip(ModeSwitch, Localizer.Get("ProfileModeTip"));
        ImportItem.Text = Localizer.Get("ProfileImport");
        SaveAsItem.Text = Localizer.Get("ProfileSaveAs");
        OpenFolderItem.Text = Localizer.Get("AdvancedFiles.OpenFolder");
        DeleteItem.Text = Localizer.Get("DeleteAction");
        AppToolTip.SetTip(MoreButton, Localizer.Get("ProfileMoreActions"));
        AutomationProperties.SetName(MoreButton, Localizer.Get("ProfileMoreActions"));
        ZoomAllButton.Content = Localizer.Get("ProfileZoomAll");
        ZoomSelectionButton.Content = Localizer.Get("ProfileZoomSelection");
        // How to use the graph, one hover away instead of a line of text under it.
        AppToolTip.SetTip(ChartHelp, string.Join("\n", Localizer.Get("ProfileChartHint").Split(" · ")));
        AutomationProperties.SetName(ChartHelp, Localizer.Get("ProfileChartHelp"));
        AppToolTip.SetTip(CopyResultsButton, Localizer.Get("ProfileCopyResults"));
        AutomationProperties.SetName(CopyResultsButton, Localizer.Get("ProfileCopyResults"));
        LuaTab.Text = Localizer.Get("ProfileTabLua");
        JavaTab.Text = Localizer.Get("ProfileTabJava");
        FewSamplesInfo.Message = Localizer.Get("ProfileFewSamples");
        var thread = ThreadBox.SelectedIndex;
        ThreadBox.Items.Clear();
        ThreadBox.Items.Add(Localizer.Get("ProfileThreadGame"));
        ThreadBox.Items.Add(Localizer.Get("ProfileThreadAll"));
        ThreadBox.SelectedIndex = Math.Max(0, thread);
        UpdateSession();
        // The graph's scale is drawn in code with the language's number format.
        if (IsLoaded) { RefreshList(loadedPath); RenderChart(); if (shown is not null) ShowRange(shown); }
    }

    internal void RefreshForNavigation()
    {
        Attach();
        RefreshList(loadedPath);
    }

    private void FollowVisibility()
    {
        if (Visibility == Visibility.Visible)
        {
            if (!gameClock.IsEnabled) { gameClock.Start(); _ = CheckGamesAsync(); }
        }
        else gameClock.Stop();
    }

    private void Attach()
    {
        if (App.Host is not { } host || ReferenceEquals(service, host.Profiles)) return;
        if (service is not null) service.Changed -= Session_Changed;
        service = host.Profiles;
        service.Changed += Session_Changed;
        UpdateSession();
        RefreshList(loadedPath);
    }

    private void Session_Changed() => DispatcherQueue.TryEnqueue(UpdateSession);

    // ---- Recording ----

    private void UpdateSession()
    {
        var session = service?.Session ?? new ProfileSession(ProfileSessionState.Idle);
        var idle = session.State == ProfileSessionState.Idle;
        RecordText.Text = Localizer.Get(idle ? "ProfileRecordStart" : "ProfileRecordStop");
        RecordIcon.Glyph = idle ? "\uE7C8" : "\uE71A"; // record : stop
        // Starting needs exactly one game; stopping is possible as soon as the game has confirmed the recording;
        // converting cannot be interrupted.
        RecordButton.IsEnabled = idle ? games is -1 or 1 : session.State == ProfileSessionState.Recording;
        var why = !idle || games is -1 or 1 ? null
            : Localizer.Get(games == 0 ? "ProfileNeedsGame" : "ProfileError.MultipleGames");
        AppToolTip.SetTip(RecordHost, why);
        AutomationProperties.SetHelpText(RecordButton, why ?? "");
        ModeSwitch.IsEnabled = idle;
        if (!idle) ModeSwitch.IsOn = session.Detailed;
        StatusText.Text = session.State switch
        {
            ProfileSessionState.Starting => Localizer.Get("ProfileStarting"),
            ProfileSessionState.Recording => Localizer.Format("ProfileRecordingFormat",
                Elapsed(DateTimeOffset.UtcNow - (session.RecordingSinceUtc ?? DateTimeOffset.UtcNow)), session.LimitSeconds / 60),
            ProfileSessionState.Converting => Localizer.Get("ProfileConverting"),
            _ => "",
        };
        StatusPanel.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        var note = session.State != ProfileSessionState.Recording ? null
            : !session.LuaAvailable ? Localizer.Get("ProfileNoLua")
            : !session.HasFrames ? Localizer.Get("ProfileNoFrames") : null;
        StatusNote.Text = note ?? "";
        StatusNote.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
        if (session.State == ProfileSessionState.Recording) clock.Start(); else clock.Stop();
    }

    private async Task CheckGamesAsync()
    {
        if (service is not { } profiles || checkingGames) return;
        checkingGames = true;
        try
        {
            var count = await Task.Run(profiles.RunningGames);
            if (count == games) return;
            games = count;
            UpdateSession();
        }
        catch (Exception) { }
        finally { checkingGames = false; }
    }

    private static string Elapsed(TimeSpan time) =>
        $"{(int)Math.Max(0, time.TotalMinutes):00}:{Math.Max(0, time.Seconds):00}";

    private async void RecordButton_Click(object sender, RoutedEventArgs e)
    {
        Attach();
        if (service is not { } profiles || App.Host?.Operations is null)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Warning, Localizer.Get("ProfilerNavigation"), Localizer.Get("HostNotReady"));
            return;
        }
        if (profiles.Session.State != ProfileSessionState.Idle) { profiles.Stop(); return; }
        try
        {
            var (path, result) = await profiles.RecordAsync(ModeSwitch.IsOn);
            if (path is null)
            {
                var message = Localizer.Get(ProfileRecordingService.ErrorKey(result));
                if (result.RunIndex > 0)
                    // The recording ran as a worker: its own card shows the outcome and its log holds it. Name the
                    // reason there, instead of a second card and a second log entry for the same click.
                    App.ExplainOnOperationCard(result.OperationId, message);
                else
                    // Refused before any work started. No game, or other work running, is nothing to log.
                    App.ShowSidebarNotification(result.Error is "profile-game-not-running" or "profile-multiple-games"
                            or "operation-busy" ? InfoBarSeverity.Informational : InfoBarSeverity.Error,
                        Localizer.Get("ProfilerNavigation"), message);
                _ = CheckGamesAsync();
                return;
            }
            RefreshList(path);
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("ProfilerNavigation"), UserFacingError.FromException(exception));
        }
    }

    // ---- Recordings ----

    private sealed record RecordingItem(ProfileFile File, string Text)
    {
        public override string ToString() => Text;
    }

    private void RefreshList(string? select)
    {
        if (service is null) return;
        var files = service.List();
        updatingList = true;
        RecordingList.Items.Clear();
        foreach (var file in files)
            RecordingList.Items.Add(new RecordingItem(file, Localizer.Format("ProfileRecordingItemFormat",
                file.CreatedUtc.ToLocalTime().ToString("g", Localizer.Culture), file.Bytes / 1024.0)));
        var index = select is null ? -1 : files.ToList().FindIndex(file => file.Path.Equals(select, StringComparison.OrdinalIgnoreCase));
        if (index < 0 && files.Count > 0) index = 0;
        RecordingList.SelectedIndex = index;
        RecordingList.PlaceholderText = Localizer.Get("ProfileEmpty");
        updatingList = false;
        DeleteItem.IsEnabled = SaveAsItem.IsEnabled = index >= 0;
        var path = index < 0 ? null : files[index].Path;
        // With nothing recorded yet, the empty page says how to make a recording.
        if (path is null) Clear(Localizer.Get("ProfileIdleHint"));
        else if (!path.Equals(loadedPath, StringComparison.OrdinalIgnoreCase)) _ = LoadAsync(path);
    }

    private void RecordingList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (updatingList) return;
        DeleteItem.IsEnabled = SaveAsItem.IsEnabled = RecordingList.SelectedItem is RecordingItem;
        if (RecordingList.SelectedItem is RecordingItem item) _ = LoadAsync(item.File.Path);
    }

    private async Task LoadAsync(string path)
    {
        var version = ++loadVersion;
        loadedPath = path;
        recording = null;
        shown = null;
        HideResults();
        EmptyPanel.Visibility = Visibility.Visible;
        EmptyText.Text = "";
        LoadingRing.Visibility = Visibility.Visible;
        LoadingRing.IsActive = true;
        ProfileRecording? loaded = null;
        try { loaded = await Task.Run(() => ProfileRecording.Load(path)); }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException) { }
        if (version != loadVersion) return;
        LoadingRing.IsActive = false;
        LoadingRing.Visibility = Visibility.Collapsed;
        if (loaded is null || loaded.Duration <= 0) { loadedPath = null; Clear(Localizer.Get("ProfileLoadFailed")); return; }
        recording = loaded;
        viewStart = 0;
        viewEnd = loaded.Duration;
        selectionStart = selectionEnd = null;
        EmptyPanel.Visibility = Visibility.Collapsed;
        ChartPanel.Visibility = ResultsGrid.Visibility = Visibility.Visible;
        ThreadBox.IsEnabled = loaded.GameThread >= 0;
        if (loaded.GameThread < 0) ThreadBox.SelectedIndex = 1;
        chartEntrance = Motion;
        RenderChart();
        Analyze();
    }

    private void Clear(string message)
    {
        loadVersion++;
        recording = null;
        loadedPath = null;
        shown = null;
        HideResults();
        LoadingRing.IsActive = false;
        LoadingRing.Visibility = Visibility.Collapsed;
        EmptyPanel.Visibility = Visibility.Visible;
        EmptyText.Text = message;
    }

    private void HideResults()
    {
        ChartPanel.Visibility = ResultsGrid.Visibility = Visibility.Collapsed;
        FewSamplesInfo.IsOpen = false;
    }

    private async void ImportItem_Click(object sender, RoutedEventArgs e)
    {
        Attach();
        if (service is null) return;
        try
        {
            var picker = new FileOpenPicker(App.MainWindow.AppWindow.Id);
            picker.FileTypeFilter.Add(ProfileRecording.Extension);
            var file = await picker.PickSingleFileAsync();
            if (file is null) return;
            var imported = await Task.Run(() => service.Import(file.Path));
            RefreshList(imported);
        }
        catch (Exception exception) when (exception is InvalidDataException or FormatException or EndOfStreamException)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("ProfilerNavigation"), Localizer.Get("ProfileLoadFailed"));
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("ProfilerNavigation"), UserFacingError.FromException(exception));
        }
    }

    private async void SaveAsItem_Click(object sender, RoutedEventArgs e)
    {
        if (service is null || RecordingList.SelectedItem is not RecordingItem item) return;
        try
        {
            var picker = new FileSavePicker(App.MainWindow.AppWindow.Id) { SuggestedFileName = item.File.Name };
            picker.FileTypeChoices.Add(Localizer.Get("ProfileFileType"), [ProfileRecording.Extension]);
            var file = await picker.PickSaveFileAsync();
            if (file is null) return;
            await Task.Run(() => service.Export(item.File.Path, file.Path));
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("ProfilerNavigation"), UserFacingError.FromException(exception));
        }
    }

    private void OpenFolderItem_Click(object sender, RoutedEventArgs e)
    {
        if (service is null) return;
        try
        {
            Directory.CreateDirectory(service.Directory);
            var selected = (RecordingList.SelectedItem as RecordingItem)?.File.Path;
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe")
            {
                Arguments = selected is not null && File.Exists(selected) ? $"/select,\"{selected}\"" : $"\"{service.Directory}\"",
                UseShellExecute = false,
            })?.Dispose();
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("ProfilerNavigation"), UserFacingError.FromException(exception));
        }
    }

    private async void DeleteItem_Click(object sender, RoutedEventArgs e)
    {
        if (service is null || RecordingList.SelectedItem is not RecordingItem item) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = item.Text, Content = Localizer.Get("ProfileDeleteConfirm"),
            PrimaryButtonText = Localizer.Get("DeleteAction"), CloseButtonText = Localizer.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            // Inside the try: showing a dialog throws when another one is open, and this is an async handler.
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            service.Delete(item.File.Path);
            if (item.File.Path.Equals(loadedPath, StringComparison.OrdinalIgnoreCase)) loadedPath = null;
            RefreshList(null);
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("ProfilerNavigation"), UserFacingError.FromException(exception));
        }
    }

    // ---- Chart ----

    private double ChartWidth => Math.Max(1, ChartSurface.ActualWidth);
    private double ChartHeight => Math.Max(1, ChartSurface.ActualHeight);
    private long TimeAt(double x) => viewStart + (long)(Math.Clamp(x / ChartWidth, 0, 1) * (viewEnd - viewStart));
    private double XAt(long time) => (time - viewStart) / (double)Math.Max(1, viewEnd - viewStart) * ChartWidth;

    private void ChartSurface_SizeChanged(object sender, SizeChangedEventArgs e) => RenderChart();

    private void RenderChart()
    {
        if (recording is null || ChartSurface.ActualWidth < 4) return;
        double width = ChartWidth, chartHeight = ChartHeight;
        // Under the bars, a strip on the same time scale marks each garbage collection as long as it paused the
        // game, so a spike above a mark reads as "the game stopped to collect". Only when there are any.
        const double CollectionLane = 8;
        var markCollections = recording.Collections.Count > 0;
        // Below that, memory on its own scale: the Java heap and the game's video memory as two lines.
        const double MemoryLane = 34;
        var showMemory = recording.Heap.Count > 0 || recording.VideoMemory.Count > 0;
        var height = Math.Max(1, chartHeight - (markCollections ? CollectionLane : 0) - (showMemory ? MemoryLane : 0));
        // One bar per three pixels; each holds the slowest frame of its slice.
        var buckets = Math.Max(1, (int)(width / 3));
        var values = ProfileAnalysis.SlowestFramePerBucket(recording, viewStart, viewEnd, buckets);
        var top = NiceCeiling(Math.Max(20, values.Max()));
        var normal = new GeometryGroup { FillRule = FillRule.Nonzero };
        var slow = new GeometryGroup { FillRule = FillRule.Nonzero };
        var step = width / buckets;
        for (var index = 0; index < buckets; index++)
        {
            if (values[index] <= 0) continue;
            var barHeight = Math.Max(1, Math.Min(1, values[index] / top) * height);
            var bar = new RectangleGeometry { Rect = new Rect(index * step, height - barHeight, Math.Max(1, step - 0.5), barHeight) };
            (values[index] > SlowFrameMilliseconds ? slow : normal).Children.Add(bar);
        }
        BarsPath.Data = normal;
        SlowBarsPath.Data = slow;
        if (chartEntrance)
        {
            chartEntrance = false;
            foreach (var path in new[] { BarsPath, SlowBarsPath })
            {
                path.CenterPoint = new Vector3(0, (float)height, 0);
                Grow(path, new Vector3(1, 0, 1), TimeSpan.Zero);
            }
        }

        GridCanvas.Children.Clear();
        // The same muted colour as the secondary text, whatever the theme.
        var brush = Muted;
        foreach (var fraction in new[] { 0.0, 0.5, 1.0 })
        {
            var y = height - fraction * height;
            GridCanvas.Children.Add(new Line { X1 = 0, X2 = width, Y1 = y, Y2 = y, Stroke = brush, StrokeThickness = 0.5, Opacity = 0.6 });
            var label = new TextBlock { Text = (top * fraction).ToString("0", Localizer.Culture) + " ms", FontSize = 11, Foreground = brush };
            Canvas.SetLeft(label, -42);
            Canvas.SetTop(label, Math.Max(-6, y - 8));
            GridCanvas.Children.Add(label);
        }
        foreach (var fraction in new[] { 0.0, 0.25, 0.5, 0.75, 1.0 })
        {
            var label = new TextBlock { Text = Seconds(viewStart + (long)((viewEnd - viewStart) * fraction)), FontSize = 11, Foreground = brush };
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(label, Math.Clamp(width * fraction - label.DesiredSize.Width / 2, 0, Math.Max(0, width - label.DesiredSize.Width)));
            Canvas.SetTop(label, chartHeight + 2);
            GridCanvas.Children.Add(label);
        }
        if (markCollections)
        {
            // One shape for all marks: a game that allocates a lot collects many times a second.
            var marks = new GeometryGroup { FillRule = FillRule.Nonzero };
            foreach (var collection in recording.Collections)
            {
                if (collection.Time >= viewEnd || collection.Time + collection.Duration < viewStart) continue;
                var left = Math.Clamp(XAt(collection.Time), 0, Math.Max(0, width - 2));
                // A pause of a few milliseconds is far narrower than a pixel at most zooms: keep it visible.
                var markWidth = Math.Max(2, XAt(collection.Time + collection.Duration) - left);
                marks.Children.Add(new RectangleGeometry { Rect = new Rect(left, height + (CollectionLane - 4) / 2, markWidth, 4) });
            }
            GridCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = marks, Fill = brush });
        }
        if (showMemory) RenderMemoryLane(width, height + (markCollections ? CollectionLane : 0) + 3, MemoryLane - 6, brush);

        UpdateSelectionRectangle();
        var zoomed = viewStart > 0 || viewEnd < recording.Duration;
        ViewScroll.Visibility = zoomed ? Visibility.Visible : Visibility.Collapsed;
        if (zoomed)
        {
            updatingScroll = true;
            // Scroll positions are milliseconds: double precision is ample and the numbers stay readable.
            ViewScroll.Minimum = 0;
            ViewScroll.ViewportSize = (viewEnd - viewStart) / 1000.0;
            ViewScroll.Maximum = Math.Max(0, (recording.Duration - (viewEnd - viewStart)) / 1000.0);
            ViewScroll.LargeChange = ViewScroll.ViewportSize;
            ViewScroll.SmallChange = ViewScroll.ViewportSize / 10;
            ViewScroll.Value = viewStart / 1000.0;
            updatingScroll = false;
        }
        if (HoverLine.Visibility == Visibility.Collapsed) ShowDefaultChartInfo();
    }

    // Above the graph: the range the results describe. Its samples, collections and the recording mode
    // are one hover away, so the line stays one line.
    private void ShowDefaultChartInfo()
    {
        if (recording is null) return;
        var (start, end, frames) = shown is { } range ? (range.Start, range.End, range.Frames)
            : (0L, recording.Duration, ProfileAnalysis.FrameStatistics(recording, 0, recording.Duration));
        List<(string?, string)> items = [(null, RangeText(start, end))];
        // One frame has one time; average, slowest and worst 1% would repeat it three times.
        if (frames.Count == 1) items.Add((Localizer.Get("ProfileStatFrame"), Milliseconds(frames.SlowestMilliseconds)));
        else if (frames.Count > 1)
        {
            items.Add((Localizer.Get("ProfileStatFrames"), frames.Count.ToString("N0", Localizer.Culture)));
            items.Add((Localizer.Get("ProfileStatAverage"), Milliseconds(frames.AverageMilliseconds)));
            // Players know frame rates better than frame times: "135 ms" alone was read against the frame count.
            // Its own pair, a name and a number like the others.
            if (frames.AverageMilliseconds > 0)
                items.Add((Localizer.Get("ProfileStatFps"), (1000 / frames.AverageMilliseconds).ToString("N1", Localizer.Culture)));
            items.Add((Localizer.Get("ProfileStatSlowest"), Milliseconds(frames.SlowestMilliseconds)));
            items.Add((Localizer.Get("ProfileStatWorst"), Milliseconds(frames.OnePercentWorstMilliseconds)));
        }
        // Collections stop the game without leaving samples, so the tables cannot show them; the line does,
        // and so does the copied text, which starts with this line.
        var (collections, paused) = shown is { } analysed ? (analysed.Collections, analysed.CollectionPauseMilliseconds)
            : ProfileAnalysis.CollectionsIn(recording, start, end);
        if (collections > 0) items.Add(CollectionStat(collections, paused));
        var (heapPeak, videoPeak) = ProfileAnalysis.MemoryPeaksIn(recording, start, end);
        if (heapPeak is { } heap) items.Add((Localizer.Get("ProfileStatHeapPeak"), Bytes(heap)));
        if (videoPeak is { } video) items.Add((Localizer.Get("ProfileStatVideoPeak"), Bytes(video)));
        var lines = SetStats(ChartInfo, items);
        rangeSummary = string.Join(" · ", lines);
        if (shown is { } current)
            lines.Add(Localizer.Format("ProfileSummarySamplesFormat", current.Samples, current.Collections, current.CollectionPauseMilliseconds));
        lines.Add(Localizer.Get(recording.Detailed ? "ProfileModeDetailed" : "ProfileModeGeneral"));
        AppToolTip.SetTip(ChartInfo, string.Join("\n", lines));
    }

    // Heap in green, video memory in the text colour, both against the larger of the two peaks in view, so the
    // lines compare. The peak stands at the left, where the frame scale's labels are.
    private void RenderMemoryLane(double width, double top, double laneHeight, Brush muted)
    {
        if (recording is null) return;
        var heap = recording.Heap.Where(item => item.Time >= viewStart && item.Time <= viewEnd).Select(item => (item.Time, item.Used)).ToArray();
        var video = recording.VideoMemory.Where(item => item.Time >= viewStart && item.Time <= viewEnd).Select(item => (item.Time, Used: item.Dedicated)).ToArray();
        var peak = Math.Max(heap.Length > 0 ? heap.Max(item => item.Used) : 0, video.Length > 0 ? video.Max(item => item.Used) : 0);
        if (peak <= 0) return;
        var scale = peak * 1.1;
        GridCanvas.Children.Add(new Line { X1 = 0, X2 = width, Y1 = top + laneHeight, Y2 = top + laneHeight, Stroke = muted, StrokeThickness = 0.5, Opacity = 0.6 });
        var label = new TextBlock { Text = Bytes(peak), FontSize = 11, Foreground = muted };
        Canvas.SetLeft(label, -42);
        Canvas.SetTop(label, top - 4);
        GridCanvas.Children.Add(label);
        foreach (var (points, stroke) in new[]
        {
            (heap, (Brush)Application.Current.Resources["SystemFillColorSuccessBrush"]),
            (video, (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"]),
        })
        {
            if (points.Length == 0) continue;
            var line = new Polyline { Stroke = stroke, StrokeThickness = 1.5, IsHitTestVisible = false };
            foreach (var (time, used) in points)
                line.Points.Add(new Windows.Foundation.Point(XAt(time), top + laneHeight - used / scale * laneHeight));
            GridCanvas.Children.Add(line);
        }
    }

    private static string Bytes(long bytes) => bytes >= 1L << 30
        ? (bytes / (double)(1L << 30)).ToString("N1", Localizer.Culture) + " GB"
        : (bytes / (double)(1L << 20)).ToString("N0", Localizer.Culture) + " MB";

    private (string?, string) CollectionStat(int count, double pausedMilliseconds) =>
        (Localizer.Get("ProfileStatCollections"), Localizer.Format("ProfileCollectionsValueFormat", count, Milliseconds(pausedMilliseconds)));

    // The secondary text colour of the current theme, for names beside numbers and for the graph's scale.
    private Brush Muted => ChartHelpIcon.Foreground;

    /// <summary>
    /// Writes "name value" pairs on one line: names muted, values in the normal colour, wide gaps between the pairs
    /// instead of separator characters. Returns the same pairs one per line, for a tooltip or a screen reader.
    /// </summary>
    private List<string> SetStats(TextBlock target, IEnumerable<(string? Label, string Value)> items)
    {
        target.Inlines.Clear();
        var lines = new List<string>();
        foreach (var (label, value) in items)
        {
            if (lines.Count > 0) target.Inlines.Add(new Run { Text = "  " });
            if (label is not null) target.Inlines.Add(new Run { Text = label + " ", Foreground = Muted });
            target.Inlines.Add(new Run { Text = value });
            lines.Add(label is null ? value : label + " " + value);
        }
        AutomationProperties.SetName(target, string.Join(", ", lines));
        return lines;
    }

    private static string RangeText(long start, long end) =>
        $"{SecondsNumber(start)}–{SecondsNumber(end)} s ({SecondsNumber(end - start)} s)";

    private static string Milliseconds(double value) => value.ToString("0.0", Localizer.Culture) + " ms";

    private static double NiceCeiling(double value)
    {
        var magnitude = Math.Pow(10, Math.Floor(Math.Log10(value)));
        foreach (var factor in new[] { 1.0, 2, 2.5, 5, 10 })
            if (value <= magnitude * factor) return magnitude * factor;
        return magnitude * 10;
    }

    private static string Seconds(long microseconds) => SecondsNumber(microseconds) + " s";

    private static string SecondsNumber(long microseconds) =>
        (microseconds / 1_000_000.0).ToString(microseconds % 1_000_000 == 0 ? "0" : "0.00", Localizer.Culture);

    private void UpdateSelectionRectangle()
    {
        if (selectionStart is not { } start || selectionEnd is not { } end || end <= viewStart || start >= viewEnd)
        {
            SelectionRectangle.Visibility = Visibility.Collapsed;
            ZoomSelectionButton.IsEnabled = selectionStart is not null;
            return;
        }
        var left = Math.Max(0, XAt(start));
        var right = Math.Min(ChartWidth, XAt(end));
        Canvas.SetLeft(SelectionRectangle, left);
        Canvas.SetTop(SelectionRectangle, 0);
        SelectionRectangle.Width = Math.Max(2, right - left);
        SelectionRectangle.Height = ChartHeight;
        SelectionRectangle.Visibility = Visibility.Visible;
        ZoomSelectionButton.IsEnabled = true;
    }

    private void SetView(long start, long end)
    {
        if (recording is null) return;
        var span = Math.Clamp(end - start, Math.Min(MinimumSpan, recording.Duration), recording.Duration);
        start = Math.Clamp(start, 0, recording.Duration - span);
        viewStart = start;
        viewEnd = start + span;
        // Dragging and the wheel can move the view many times per frame; draw once for the last of them.
        if (renderQueued) return;
        renderQueued = DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            renderQueued = false;
            RenderChart();
        });
        if (!renderQueued) RenderChart();
    }

    private bool renderQueued;

    private void Chart_PointerWheelChanged(object sender, PointerRoutedEventArgs e)
    {
        if (recording is null) return;
        var point = e.GetCurrentPoint(ChartSurface);
        var delta = point.Properties.MouseWheelDelta;
        if (delta == 0) return;
        e.Handled = true; // The page must not scroll while the chart zooms.
        var span = viewEnd - viewStart;
        if (point.Properties.IsHorizontalMouseWheel || e.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Shift))
        {
            SetView(viewStart - Math.Sign(delta) * span / 8, viewEnd - Math.Sign(delta) * span / 8);
            return;
        }
        // Zoom about the pointer, as a stock chart does: what is under the cursor stays under it.
        var anchor = TimeAt(point.Position.X);
        var factor = delta > 0 ? 0.75 : 1 / 0.75;
        var nextSpan = (long)Math.Clamp(span * factor, Math.Min(MinimumSpan, recording.Duration), recording.Duration);
        var ratio = Math.Clamp(point.Position.X / ChartWidth, 0, 1);
        var start = anchor - (long)(nextSpan * ratio);
        SetView(start, start + nextSpan);
    }

    private void Chart_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (recording is null) return;
        var point = e.GetCurrentPoint(ChartSurface);
        pressX = point.Position.X;
        pressViewStart = viewStart;
        if (point.Properties.IsRightButtonPressed || point.Properties.IsMiddleButtonPressed) panning = true;
        else if (point.Properties.IsLeftButtonPressed) selecting = true;
        else return;
        ChartSurface.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void Chart_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (recording is null) return;
        var x = e.GetCurrentPoint(ChartSurface).Position.X;
        if (panning)
        {
            var shift = (long)((pressX - x) / ChartWidth * (viewEnd - viewStart));
            SetView(pressViewStart + shift, pressViewStart + shift + (viewEnd - viewStart));
            return;
        }
        if (selecting && Math.Abs(x - pressX) >= 4)
        {
            selectionStart = TimeAt(Math.Min(pressX, x));
            selectionEnd = TimeAt(Math.Max(pressX, x));
            UpdateSelectionRectangle();
        }
        var time = TimeAt(x);
        Canvas.SetLeft(HoverLine, Math.Clamp(x, 0, ChartWidth));
        HoverLine.Height = ChartHeight;
        HoverLine.Visibility = Visibility.Visible;
        var frame = ProfileAnalysis.FrameAt(recording, time);
        List<(string?, string)> items = [(null, Seconds(time))];
        if (frame is { } found && time >= found.Start)
        {
            items.Add((Localizer.Get("ProfileStatFrame"), Milliseconds(found.Duration / 1000.0)));
            // Whether this frame was slow because the game stopped to collect garbage.
            var (collections, paused) = ProfileAnalysis.CollectionsIn(recording, found.Start, found.Start + found.Duration);
            if (collections > 0) items.Add(CollectionStat(collections, paused));
        }
        var (heapNow, videoNow) = ProfileAnalysis.MemoryAt(recording, time);
        if (heapNow is { } heap) items.Add((Localizer.Get("ProfileStatHeap"), Bytes(heap.Used)));
        if (videoNow is { } video) items.Add((Localizer.Get("ProfileStatVideo"), Bytes(video.Dedicated)));
        SetStats(ChartInfo, items);
    }

    private void Chart_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (recording is null) return;
        var x = e.GetCurrentPoint(ChartSurface).Position.X;
        var wasSelecting = selecting;
        selecting = panning = false;
        ChartSurface.ReleasePointerCapture(e.Pointer);
        if (!wasSelecting) return;
        if (Math.Abs(x - pressX) < 4)
        {
            // A click picks the one frame under the pointer.
            var time = TimeAt(x);
            if (ProfileAnalysis.FrameAt(recording, time) is { } frame && time >= frame.Start && time <= frame.Start + frame.Duration)
            {
                selectionStart = frame.Start;
                selectionEnd = frame.Start + Math.Max(1, frame.Duration);
            }
            else selectionStart = selectionEnd = null;
        }
        UpdateSelectionRectangle();
        Analyze();
    }

    private void Chart_PointerCanceled(object sender, PointerRoutedEventArgs e) => selecting = panning = false;

    private void Chart_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (selecting || panning) return;
        HoverLine.Visibility = Visibility.Collapsed;
        ShowDefaultChartInfo();
    }

    private void Chart_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e) => ZoomAllButton_Click(sender, e);

    private void ZoomAllButton_Click(object sender, RoutedEventArgs e)
    {
        if (recording is null) return;
        SetView(0, recording.Duration);
    }

    private void ZoomSelectionButton_Click(object sender, RoutedEventArgs e)
    {
        if (selectionStart is not { } start || selectionEnd is not { } end) return;
        // A little room on both sides, so the edges of the selection stay visible and draggable.
        var margin = Math.Max(1, (end - start) / 10);
        SetView(start - margin, end + margin);
    }

    private void ViewScroll_Scroll(object sender, ScrollEventArgs e)
    {
        if (updatingScroll || recording is null) return;
        var start = (long)(e.NewValue * 1000);
        SetView(start, start + (viewEnd - viewStart));
    }

    // ---- Chart height ----

    private void ChartGrip_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        gripStartY = e.GetCurrentPoint(this).Position.Y;
        gripStartHeight = ChartBorder.Height;
        resizingChart = ChartGrip.CapturePointer(e.Pointer);
        e.Handled = true;
    }

    private void ChartGrip_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!resizingChart) return;
        // Enough graph to read, and never so much that the results have no room left.
        var most = Math.Max(100, ActualHeight * 0.6);
        ChartBorder.Height = Math.Clamp(gripStartHeight + e.GetCurrentPoint(this).Position.Y - gripStartY, 100, most);
        e.Handled = true;
    }

    private void ChartGrip_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!resizingChart) return;
        resizingChart = false;
        ChartGrip.ReleasePointerCaptures();
    }

    // ---- Layout ----

    private void ProfilerPage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Narrow: the recording tools go below the title, and the functions below their owners.
        var narrowHeader = e.NewSize.Width < 760;
        Grid.SetRow(Toolbar, narrowHeader ? 1 : 0);
        Grid.SetColumn(Toolbar, narrowHeader ? 0 : 1);
        Grid.SetColumnSpan(Toolbar, narrowHeader ? 2 : 1);
        Toolbar.Margin = new Thickness(0, narrowHeader ? 0 : 9, 0, 0);
        var stacked = e.NewSize.Width < 720;
        GroupColumn.Width = stacked ? new GridLength(1, GridUnitType.Star) : new GridLength(300);
        DetailColumn.Width = new GridLength(stacked ? 0 : 1, GridUnitType.Star);
        GroupRow.Height = stacked ? new GridLength(200) : new GridLength(1, GridUnitType.Star);
        DetailRow.Height = new GridLength(stacked ? 1 : 0, GridUnitType.Star);
        // Stacked, the owner's name moves from beside the tabs to just above its table.
        Grid.SetColumn(DetailTitle, stacked ? 0 : 1);
        Grid.SetRow(DetailTitle, stacked ? 2 : 0);
        DetailTitle.Margin = new Thickness(16, stacked ? 16 : 0, 16, 0);
        Grid.SetColumn(DetailCard, stacked ? 0 : 1);
        Grid.SetRow(DetailCard, stacked ? 3 : 1);
    }

    // ---- Results ----

    private enum DetailKind { Lua, Java, Threads, Pauses }

    /// <summary>One entry of the owner list: a mod, the game's scripts, a part of the game code, the threads, the pauses.</summary>
    private sealed record ResultGroup(string Key, string Name, double? Share, int Samples, DetailKind Kind,
        IReadOnlyList<ProfileShare> Rows, IReadOnlyList<ProfilePause> Pauses);

    private bool JavaShown => ReferenceEquals(ResultTabs.SelectedItem, JavaTab);

    private void ResultTabs_SelectionChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args) => ShowTab();

    private void ThreadBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (recording is not null && ThreadBox.SelectedIndex >= 0) Analyze();
    }

    private async void Analyze()
    {
        if (recording is not { } current) return;
        var version = ++analysisVersion;
        var start = selectionStart ?? 0;
        var end = selectionEnd ?? current.Duration;
        var thread = ThreadBox.SelectedIndex == 1 || current.GameThread < 0 ? -1 : current.GameThread;
        ProfileRange range;
        try { range = await Task.Run(() => ProfileAnalysis.Analyze(current, start, end, thread, RowsPerGroup)); }
        catch (Exception) { return; }
        if (version != analysisVersion || !ReferenceEquals(current, recording)) return;
        ShowRange(range);
    }

    private void ShowRange(ProfileRange range)
    {
        shown = range;
        if (HoverLine.Visibility == Visibility.Collapsed) ShowDefaultChartInfo();
        // A handful of samples cannot carry percentages; say so instead of showing confident numbers.
        FewSamplesInfo.IsOpen = range.Samples < 20;

        luaGroups = range.LuaGroups.Select(group => new ResultGroup(group.Key,
            group.Key == ProfileAnalysis.GameOwner ? Localizer.Get("ProfileOwnerGame")
            : group.Key == ProfileAnalysis.UnknownOwner ? Localizer.Get("ProfileOwnerUnknown") : group.Key,
            group.Self, group.Samples, DetailKind.Lua, group.Rows, [])).ToList();
        javaGroups = range.MethodGroups.Select(group => new ResultGroup(group.Key, Localizer.Get($"ProfileGroup.{group.Key}"),
            group.Self, group.Samples, DetailKind.Java, group.Rows, [])).ToList();
        if (range.Threads.Count > 1)
            javaGroups.Add(new ResultGroup("#threads", Localizer.Get("ProfileThreadsSection"), null,
                range.Threads.Sum(row => row.Samples), DetailKind.Threads, range.Threads, []));
        if (range.LongestPauses.Count > 0)
            javaGroups.Add(new ResultGroup("#pauses", Localizer.Get("ProfilePausesSection"), null, 0, DetailKind.Pauses, [], range.LongestPauses));
        ShowTab();
    }

    private void ShowTab()
    {
        if (shown is not { } range) return;
        var java = JavaShown;
        listedGroups = java ? javaGroups : luaGroups;
        if (listedGroups.Count == 0)
        {
            SetSplitVisible(false);
            ResultMessage.Text = Localizer.Get(java ? "ProfileFewSamples" : recording?.LuaPeriod > 0 ? "ProfileLuaNone" : "ProfileNoLua");
            return;
        }
        SetSplitVisible(true);
        GroupNameHeading.Text = Localizer.Get(java ? "ProfileListJavaOwner" : "ProfileListLuaOwner");
        GroupShareText.Text = Localizer.Get(java ? "ProfileListJavaShare" : "ProfileListLuaShare");
        AppToolTip.SetTip(GroupShareHeading, Localizer.Get(java ? "ProfileListJavaShareTip" : "ProfileListLuaShareTip"));
        // Only the scripts have a whole worth stating, beside the heading: the game code's items always add up to all of it.
        GroupShareTotal.Text = java ? "" : Percent(range.LuaShare);
        GroupShareTotal.Visibility = java ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(GroupShareHeading, java ? GroupShareText.Text : $"{GroupShareText.Text} {GroupShareTotal.Text}");
        // Bars are relative to the largest owner, so the list reads as a ranking; the number is the real share.
        var largest = listedGroups.Max(group => group.Share ?? 0);
        updatingGroups = true;
        GroupList.Items.Clear();
        for (var position = 0; position < listedGroups.Count; position++)
            GroupList.Items.Add(GroupItem(listedGroups[position], largest, position));
        var remembered = java ? javaSelection : luaSelection;
        var index = Math.Max(0, listedGroups.FindIndex(group => group.Key == remembered));
        GroupList.SelectedIndex = index;
        updatingGroups = false;
        ShowGroup(listedGroups[index]);
    }

    private void GroupList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (updatingGroups || GroupList.SelectedIndex < 0 || GroupList.SelectedIndex >= listedGroups.Count) return;
        var group = listedGroups[GroupList.SelectedIndex];
        if (JavaShown) javaSelection = group.Key; else luaSelection = group.Key;
        ShowGroup(group);
    }

    private void SetSplitVisible(bool visible)
    {
        GroupCard.Visibility = DetailCard.Visibility = DetailTitle.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        ResultMessage.Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
    }

    private bool Motion => uiSettings.AnimationsEnabled;

    private Grid GroupItem(ResultGroup group, double largest, int position)
    {
        var item = new Grid { Padding = new Thickness(12, 8, 4, 8), ColumnSpacing = 8, RowSpacing = 6 };
        item.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        item.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        item.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        item.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        item.Children.Add(new TextBlock { Text = group.Name, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap });
        var value = new TextBlock { Text = ValueOf(group), Foreground = Muted };
        Grid.SetColumn(value, 1);
        item.Children.Add(value);
        if (group.Share is { } part && largest > 0)
        {
            var fraction = Math.Clamp(part / largest, 0, 1);
            var bar = new Grid { Height = 3 };
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(fraction, GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1 - fraction, GridUnitType.Star) });
            var fill = new Rectangle { Fill = BarsPath.Fill, Opacity = 0.7, RadiusX = 1.5, RadiusY = 1.5 };
            // Each bar fills from the left when the list appears, one shortly after another.
            // Once: a row scrolled out of view and back is loaded again and must not fill again.
            var grown = !Motion;
            fill.Loaded += (_, _) =>
            {
                if (grown) return;
                grown = true;
                Grow(fill, new Vector3(0, 1, 1), TimeSpan.FromMilliseconds(Math.Min(position, 10) * 30));
            };
            bar.Children.Add(fill);
            Grid.SetRow(bar, 1);
            Grid.SetColumnSpan(bar, 2);
            item.Children.Add(bar);
        }
        var samples = group.Samples > 0 ? $"\n{Localizer.Get("ProfileColumnSamples")} {group.Samples.ToString("N0", Localizer.Culture)}" : "";
        AppToolTip.SetTip(item, group.Name + samples);
        AutomationProperties.SetName(item, group.Name + (value.Text.Length > 0 ? ", " + value.Text : ""));
        return item;
    }

    /// <summary>The number beside an owner: its share, or for the pauses how many there were, with a unit so it is not read as a share.</summary>
    private static string ValueOf(ResultGroup group) =>
        group.Share is { } share ? Percent(share)
        : group.Kind == DetailKind.Pauses ? Localizer.Format("ProfilePauseCount", group.Pauses.Count.ToString("N0", Localizer.Culture)) : "";

    /// <summary>The right pane: the chosen owner's functions as a table with a heading over every column.</summary>
    private void ShowGroup(ResultGroup group)
    {
        // Above the table, outside it: whose functions these are and its samples out of the tab's.
        // Its share is not repeated here; the list beside shows it.
        DetailName.Text = group.Name;
        AppToolTip.SetTip(DetailName, group.Name);
        SetStats(DetailSamples, SamplesOf(group) is { } samples ? [(Localizer.Get("ProfileColumnSamples"), samples)] : []);

        var (columns, header, rows) = Table(group);
        DetailHeader.Child = TableRow(columns, header, header: true);
        DetailRows.Children.Clear();
        foreach (var row in rows) DetailRows.Children.Add(TableRow(columns, row, header: false));
    }

    /// <summary>An owner's samples out of its tab's, such as "9/70", or null for an owner that has none.</summary>
    private string? SamplesOf(ResultGroup group)
    {
        if (group.Samples <= 0) return null;
        var total = group.Kind == DetailKind.Lua ? shown?.LuaSamples ?? 0 : shown?.Samples ?? 0;
        return $"{group.Samples.ToString("N0", Localizer.Culture)}/{total.ToString("N0", Localizer.Culture)}";
    }

    /// <summary>
    /// One owner's table: its columns, their headings and its rows. A cell's tip is its full text where the
    /// screen shows less (a method's package, a script's path), which is also what a copy carries.
    /// </summary>
    private (GridLength[] Columns, (string Text, string? Tip, bool Right)[] Header, List<(string Text, string? Tip, bool Right)[]> Rows)
        Table(ResultGroup group)
    {
        GridLength Star(double weight) => new(weight, GridUnitType.Star);
        GridLength Fixed(double width) => new(width);
        var numbers = new[] { Fixed(64), Fixed(64), Fixed(60) };
        var columns = group.Kind switch
        {
            DetailKind.Lua => [Star(3), Star(2), .. numbers],
            DetailKind.Pauses => [Fixed(90), Fixed(90), Star(1), Star(2)],
            _ => (GridLength[])[Star(1), .. numbers],
        };
        var columnsTip = Localizer.Get("ProfileColumnsTip");
        (string, string?, bool)[] Numbers() =>
        [
            (Localizer.Get("ProfileColumnSelf"), columnsTip, true),
            (Localizer.Get("ProfileColumnTotal"), columnsTip, true),
            (Localizer.Get("ProfileColumnSamples"), null, true),
        ];
        (string Text, string? Tip, bool Right)[] header = group.Kind switch
        {
            DetailKind.Lua => [(Localizer.Get("ProfileColumnFunction"), null, false), (Localizer.Get("ProfileColumnFile"), null, false), .. Numbers()],
            DetailKind.Java => [(Localizer.Get("ProfileColumnMethod"), null, false), .. Numbers()],
            DetailKind.Threads => [(Localizer.Get("ProfileColumnThread"), null, false), .. Numbers()],
            _ =>
            [
                (Localizer.Get("ProfileColumnTime"), null, false), (Localizer.Get("ProfileColumnLength"), null, true),
                (Localizer.Get("ProfileColumnKind"), null, false), (Localizer.Get("ProfileColumnDetail"), null, false),
            ],
        };
        var rows = new List<(string Text, string? Tip, bool Right)[]>();
        if (group.Kind == DetailKind.Pauses)
        {
            foreach (var pause in group.Pauses)
            {
                var detail = string.Join(" · ", new[]
                {
                    pause.Detail is "?" or "" ? null : pause.Detail,
                    pause.Thread >= 0 && recording is not null && pause.Thread < recording.Threads.Count ? recording.Threads[pause.Thread] : null,
                }.OfType<string>());
                rows.Add(
                [
                    (Seconds(pause.Time), null, false), (Milliseconds(pause.Duration / 1000.0), null, true),
                    (pause.Kind, null, false), (detail, detail, false),
                ]);
            }
            return (columns, header, rows);
        }
        foreach (var row in group.Rows)
        {
            (string, string?, bool)[] name = group.Kind switch
            {
                DetailKind.Lua => [(row.Name, row.Name, false), (LuaFileName(row.Detail), row.Detail, false)],
                DetailKind.Java => [(ShortMethod(row.Name), row.Name, false)],
                _ => [(row.Name, row.Name, false)],
            };
            rows.Add([.. name, (Percent(row.Self), null, true), (Percent(row.Total), null, true), (row.Samples.ToString("N0", Localizer.Culture), null, true)]);
        }
        return (columns, header, rows);
    }

    private Grid TableRow(IReadOnlyList<GridLength> columns, IReadOnlyList<(string Text, string? Tip, bool Right)> cells, bool header)
    {
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, header ? 0 : 5, 0, header ? 0 : 5) };
        foreach (var width in columns) row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        for (var index = 0; index < cells.Count; index++)
        {
            var (text, tip, right) = cells[index];
            var cell = new TextBlock
            {
                Text = text, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap,
                HorizontalAlignment = right ? HorizontalAlignment.Right : HorizontalAlignment.Stretch,
                TextAlignment = right ? TextAlignment.Right : TextAlignment.Left,
            };
            if (header) cell.Foreground = Muted;
            if (tip is { Length: > 0 } && (header || tip != text)) AppToolTip.SetTip(cell, tip);
            Grid.SetColumn(cell, index);
            row.Children.Add(cell);
        }
        return row;
    }

    // ---- Copy ----

    /// <summary>
    /// The page as text, as it reads on screen: the recording, the range, the tab's owners and the chosen
    /// owner's table. Meant to be pasted into a message, so the table's columns are padded to line up.
    /// </summary>
    private void CopyResultsButton_Click(object sender, RoutedEventArgs e)
    {
        if (recording is null || shown is null) return;
        var text = new System.Text.StringBuilder();
        text.AppendLine(string.Join(" · ", new[]
        {
            (RecordingList.SelectedItem as RecordingItem)?.Text,
            Localizer.Get(recording.Detailed ? "ProfileModeDetailed" : "ProfileModeGeneral"),
            ThreadBox.SelectedItem as string,
        }.Where(part => !string.IsNullOrEmpty(part))));
        text.AppendLine(rangeSummary);
        text.AppendLine();
        text.AppendLine(JavaShown ? JavaTab.Text : LuaTab.Text);
        if (listedGroups.Count == 0) text.AppendLine(ResultMessage.Text);
        else
        {
            // The list as it reads: its headings (with the scripts' total), then each owner.
            var share = GroupShareTotal.Text.Length > 0 ? $"{GroupShareText.Text} {GroupShareTotal.Text}" : GroupShareText.Text;
            var list = new List<(string Text, string? Tip, bool Right)[]>
            {
                new[] { (GroupNameHeading.Text, (string?)null, false), (share, (string?)null, true) },
            };
            list.AddRange(listedGroups.Select(group => new[] { (group.Name, (string?)null, false), (ValueOf(group), (string?)null, true) }));
            AppendTable(text, list, "  ");
        }
        if (GroupList.SelectedIndex >= 0 && GroupList.SelectedIndex < listedGroups.Count)
        {
            var group = listedGroups[GroupList.SelectedIndex];
            var (_, header, rows) = Table(group);
            text.AppendLine();
            text.AppendLine(SamplesOf(group) is { } samples ? $"{group.Name}  {Localizer.Get("ProfileColumnSamples")} {samples}" : group.Name);
            var all = new List<(string Text, string? Tip, bool Right)[]> { header };
            all.AddRange(rows);
            AppendTable(text, all, "");
        }
        try
        {
            var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
            package.SetText(text.ToString().TrimEnd());
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
            App.ShowSidebarNotification(InfoBarSeverity.Success, Localizer.Get("ProfilerNavigation"), Localizer.Get("ProfileResultsCopied"));
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("ProfilerNavigation"), UserFacingError.FromException(exception));
        }
    }

    /// <summary>Rows of cells as lines of text, each column padded to its widest cell so the columns line up.</summary>
    private static void AppendTable(System.Text.StringBuilder text, IReadOnlyList<(string Text, string? Tip, bool Right)[]> rows, string indent)
    {
        var widths = Enumerable.Range(0, rows[0].Length).Select(column => rows.Max(row => row[column].Text.Length)).ToArray();
        foreach (var row in rows)
            text.AppendLine(indent + string.Join("  ", row.Select((cell, column) =>
                cell.Right ? cell.Text.PadLeft(widths[column]) : cell.Text.PadRight(widths[column]))).TrimEnd());
    }

    /// <summary>Grows an element to its full size from <paramref name="from"/> (scale about its CenterPoint).</summary>
    private static void Grow(UIElement element, Vector3 from, TimeSpan delay)
    {
        var compositor = Microsoft.UI.Xaml.Media.CompositionTarget.GetCompositorForCurrentThread();
        var grow = compositor.CreateVector3KeyFrameAnimation();
        grow.Target = "Scale";
        grow.InsertKeyFrame(0, from);
        grow.InsertKeyFrame(1, Vector3.One, compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f)));
        grow.Duration = TimeSpan.FromMilliseconds(500);
        grow.DelayTime = delay;
        grow.DelayBehavior = Microsoft.UI.Composition.AnimationDelayBehavior.SetInitialValueBeforeDelay;
        element.StartAnimation(grow);
    }

    private static string Percent(double share) => (share * 100).ToString("0.0", Localizer.Culture) + "%";

    private static string LuaFileName(string file)
    {
        var slash = file.LastIndexOf('/');
        var name = slash < 0 ? file : file[(slash + 1)..];
        return name is "?" ? "" : name;
    }

    // "zombie.iso.IsoCell.update" reads well enough as "IsoCell.update"; the full name is in the tooltip.
    private static string ShortMethod(string method)
    {
        var last = method.LastIndexOf('.');
        var previous = last <= 0 ? -1 : method.LastIndexOf('.', last - 1);
        return previous < 0 ? method : method[(previous + 1)..];
    }
}
