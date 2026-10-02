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
    // What the analysis keeps per group: enough that a group's gathered rest is its real rest.
    private const int MaximumGroupRows = 5000;
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
    private CancellationTokenSource? analysisCancel;
    private double gripStartY, gripStartHeight;
    private bool resizingChart, updatingGroups;
    private ProfileRange? shown;
    // The summary above the graph as plain text, for a copy of the page; the line itself changes while hovering.
    private string rangeSummary = "";
    // A newly opened recording's bars rise from the baseline once, the first time the graph is drawn.
    private bool chartEntrance;
    private List<ResultGroup> luaGroups = [], javaGroups = [], allocationGroups = [], listedGroups = [];
    // The owner picked in each tab; a new range keeps it when the owner is still there.
    private string? luaSelection, javaSelection, allocationSelection;
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
        AllocationTab.Text = Localizer.Get("ProfileTabAllocation");
        // One name, on or off, like the recording mode's switch.
        CallTreeToggle.OnContent = CallTreeToggle.OffContent = Localizer.Get("ProfileCallTree");
        AutomationProperties.SetName(CallTreeToggle, Localizer.Get("ProfileCallTree"));
        CopyResultsText.Text = Localizer.Get("ProfileCopyText");
        // Set here too, not only when a recording opens: a language changed with a recording open kept the old word.
        MemoryToggleText.Text = Localizer.Get("ProfileMemory");
        AutomationProperties.SetName(MemoryToggle, Localizer.Get("ProfileMemory"));
        AppToolTip.SetTip(CallTreeToggle, Localizer.Get("ProfileCallTreeTip"));
        if (IsLoaded) ApplyLayout(ActualWidth);
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
        // Paths name functions by their number in one recording; a new recording starts with nothing highlighted.
        openPaths.Clear();
        luaHighlight = javaHighlight = allocationHighlight = null;
        previewGroup = null;
        viewStart = 0;
        viewEnd = loaded.Duration;
        selectionStart = selectionEnd = null;
        EmptyPanel.Visibility = Visibility.Collapsed;
        ChartPanel.Visibility = ResultsGrid.Visibility = Visibility.Visible;
        ThreadBox.IsEnabled = loaded.GameThread >= 0;
        if (loaded.GameThread < 0) ThreadBox.SelectedIndex = 1;
        chartEntrance = Motion;
        AllocationTab.Visibility = loaded.HasLuaAllocations ? Visibility.Visible : Visibility.Collapsed;
        if (!loaded.HasLuaAllocations && ReferenceEquals(ResultTabs.SelectedItem, AllocationTab)) ResultTabs.SelectedItem = LuaTab;
        ApplyLayout(ActualWidth);
        ApplyMemoryPanel();
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
        double width = ChartWidth, chartHeight = ChartHeight, height = chartHeight;
        // One bar per three pixels; each holds the slowest frame of its slice.
        var buckets = Math.Max(1, (int)(width / 3));
        var values = ProfileAnalysis.SlowestFramePerBucket(recording, viewStart, viewEnd, buckets);
        // A highlighted owner: its part of each bar's frame, which sets the scale while it is drawn. A mod is usually a
        // few milliseconds of a frame; on the frames' scale its part lay along the floor. The frames, faded behind,
        // reach the top where they are longer.
        var highlighted = HighlightedOwner();
        double[]? parts = null;
        if (highlighted is { } owner)
        {
            parts = ProfileAnalysis.OwnerTimePerBucket(recording, viewStart, viewEnd, buckets, owner.Java, owner.Key, recording.GameThread);
            // Sampled in steps of a period, a part can come out a little over its frame: never above its bar.
            for (var index = 0; index < buckets; index++) parts[index] = Math.Min(parts[index], values[index]);
        }
        var scaled = parts ?? values;
        var top = parts is null ? NiceCeiling(Math.Max(20, Math.Min(values.Max(), SpikeCeiling(values, SlowFrameMilliseconds))))
            : NiceCeiling(Math.Max(2, Math.Min(parts.Max(), SpikeCeiling(parts, 0))));
        var normal = new GeometryGroup { FillRule = FillRule.Nonzero };
        var slow = new GeometryGroup { FillRule = FillRule.Nonzero };
        var part = new GeometryGroup { FillRule = FillRule.Nonzero };
        var clipped = new GeometryGroup { FillRule = FillRule.Nonzero };
        var step = width / buckets;
        for (var index = 0; index < buckets; index++)
        {
            if (values[index] <= 0) continue;
            var barHeight = Math.Max(1, Math.Min(1, values[index] / top) * height);
            var bar = new RectangleGeometry { Rect = new Rect(index * step, height - barHeight, Math.Max(1, step - 0.5), barHeight) };
            (values[index] > SlowFrameMilliseconds ? slow : normal).Children.Add(bar);
            if (parts is not null && parts[index] > 0)
            {
                var partHeight = Math.Max(1, Math.Min(1, parts[index] / top) * height);
                part.Children.Add(new RectangleGeometry { Rect = new Rect(index * step, height - partHeight, Math.Max(1, step - 0.5), partHeight) });
            }
            // Taller than the scale: cut at the top and marked, its time one hover away. While an owner is drawn, its
            // parts are what the scale measures, so they are what is marked.
            if (scaled[index] > top)
            {
                var middle = index * step + Math.Max(1, step - 0.5) / 2;
                clipped.Children.Add(new PathGeometry
                {
                    Figures =
                    {
                        new PathFigure
                        {
                            StartPoint = new Windows.Foundation.Point(middle - 4, 6), IsClosed = true, IsFilled = true,
                            Segments =
                            {
                                new LineSegment { Point = new Windows.Foundation.Point(middle, 0) },
                                new LineSegment { Point = new Windows.Foundation.Point(middle + 4, 6) },
                            },
                        },
                    },
                });
            }
        }
        BarsPath.Data = normal;
        SlowBarsPath.Data = slow;
        // Faint: on the owner's scale most frames reach the top, and a wall of them would compete with its part.
        BarsPath.Opacity = SlowBarsPath.Opacity = parts is null ? 1 : 0.15;
        HighlightPath.Data = parts is null ? null : part;
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
        ReferenceCanvas.Children.Clear();
        // The same muted colour as the secondary text, whatever the theme.
        var brush = Muted;
        // 60 and 30 frames per second as dashed lines: the scale follows each recording, these do not, so "above the
        // 30 FPS line" reads the same on a fast computer's 50 ms graph and a slow one's 300 ms graph. Only where they
        // stand apart from the floor and from each other. Over the bars, so a slow recording's bars do not hide them.
        var fpsLines = new List<(int Fps, double Y)>();
        var lastLine = height;
        foreach (var (fps, milliseconds) in new[] { (60, 1000.0 / 60), (30, 1000.0 / 30) })
        {
            if (milliseconds >= top) continue;
            var y = height - milliseconds / top * height;
            // Clear of the floor by a little, of the line below by a name's height.
            if (lastLine - y < (lastLine == height ? 8 : 14)) continue;
            lastLine = y;
            fpsLines.Add((fps, y));
            ReferenceCanvas.Children.Add(new Line
            {
                X1 = 0, X2 = width, Y1 = y, Y2 = y, Stroke = brush, StrokeThickness = 1, Opacity = 0.8,
                StrokeDashArray = new DoubleCollection { 4, 3 },
            });
            // Its name in the scale's margin, on a solid pill unlike the plain scale values: inside the graph, among the
            // bars, it could hardly be read.
            var name = new Border
            {
                Background = brush, CornerRadius = new CornerRadius(7), Padding = new Thickness(5, 0, 5, 1),
                Child = new TextBlock { Text = $"{fps} {Localizer.Get("ProfileStatFps")}", FontSize = 10, Foreground = SolidBaseProbe.Background },
            };
            name.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(name, -4 - name.DesiredSize.Width);
            Canvas.SetTop(name, y - name.DesiredSize.Height / 2);
            ReferenceCanvas.Children.Add(name);
        }
        foreach (var fraction in new[] { 0.0, 0.5, 1.0 })
        {
            var y = height - fraction * height;
            GridCanvas.Children.Add(new Line { X1 = 0, X2 = width, Y1 = y, Y2 = y, Stroke = brush, StrokeThickness = 0.5, Opacity = 0.6 });
            // A scale value an FPS name would cover gives way to it; the floor needs no "0 ms" to be read.
            if (fpsLines.Any(line => Math.Abs(line.Y - y) < 14)) continue;
            // Half of a fine step can have a decimal (7.5 ms); whole numbers stay whole.
            GridCanvas.Children.Add(ScaleLabel((top * fraction).ToString("0.#", Localizer.Culture) + " ms", 11, Math.Max(-6, y - 8)));
        }
        foreach (var fraction in new[] { 0.0, 0.25, 0.5, 0.75, 1.0 })
        {
            var label = new TextBlock { Text = Seconds(viewStart + (long)((viewEnd - viewStart) * fraction)), FontSize = 11, Foreground = brush };
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(label, Math.Clamp(width * fraction - label.DesiredSize.Width / 2, 0, Math.Max(0, width - label.DesiredSize.Width)));
            Canvas.SetTop(label, chartHeight + 2);
            GridCanvas.Children.Add(label);
        }
        if (clipped.Children.Count > 0)
            GridCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = clipped, Fill = VideoBrush });
        RenderMemoryPanel();

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
        var lines = SetStats(ChartInfo, items);
        // Collections stop the game without leaving samples, so the tables cannot show them. They and the
        // memory peaks stand on the memory panel's line under the bars, and in the copied text, which starts with this line.
        var (collections, paused) = shown is { } analysed ? (analysed.Collections, analysed.CollectionPauseMilliseconds)
            : ProfileAnalysis.CollectionsIn(recording, start, end);
        var (heapPeak, videoPeak) = ProfileAnalysis.MemoryPeaksIn(recording, start, end);
        var lanes = SetLaneInfo(collections > 0 ? CollectionText(collections, paused) : null,
            heapPeak is { } heap ? $"{Localizer.Get("ProfileStatHeapPeak")} {Bytes(heap)}" : null,
            videoPeak is { } video ? $"{Localizer.Get("ProfileStatVideoPeak")} {Bytes(video)}" : null);
        lines.AddRange(lanes);
        rangeSummary = string.Join(" · ", lines);
        if (shown is { } current)
        {
            lines.Add(Localizer.Format("ProfileSummarySamplesFormat", current.Samples, current.Collections, current.CollectionPauseMilliseconds));
            // Samples of a thread only waiting in a native call are not counted as its time; say how many.
            if (current.WaitingSamples > 0)
                lines.Add(Localizer.Format("ProfileWaitingSamplesFormat", current.WaitingSamples.ToString("N0", Localizer.Culture)));
        }
        lines.Add(Localizer.Get(recording.Detailed ? "ProfileModeDetailed" : "ProfileModeGeneral"));
        AppToolTip.SetTip(ChartInfo, string.Join("\n", lines));
    }

    /// <summary>
    /// The scale stops at about twice the 95th percentile of the bars in view, never below <paramref name="floor"/> (30
    /// frames per second for frames): one loading frame of seconds no longer flattens every ordinary one to the floor.
    /// </summary>
    private static double SpikeCeiling(double[] values, double floor)
    {
        var bars = values.Where(value => value > 0).Order().ToArray();
        return bars.Length == 0 ? 0 : Math.Max(floor, bars[(int)((bars.Length - 1) * 0.95)] * 2);
    }

    // ---- Memory ----

    // Open or shut for as long as the app runs, whichever recording is shown.
    private static bool memoryOpen;

    // The panel's rows: heap, collections and video memory, each only when the recording has it, and the allocations
    // of the highlighted mod when the recording has allocations.
    private int MemoryRows => recording is not { } loaded ? 0
        : (loaded.Heap.Count > 0 ? 1 : 0) + (loaded.Collections.Count > 0 ? 1 : 0) + (loaded.VideoMemory.Count > 0 ? 1 : 0)
            + (AllocationOwner is null ? 0 : 1);

    // The heap, collections and video memory are the whole game's and cannot be split by mod. What can is the memory a
    // mod's scripts allocate: a highlighted script owner gets its own row of that, beside the collections it brings on.
    private HighlightedGroup? AllocationOwner =>
        recording?.HasLuaAllocations == true && HighlightedOwner() is { Java: false } owner ? owner : null;

    private const double MemoryRowHeight = 36, MemoryRowGap = 10;

    // The line under the frames and its button: shown when the recording has collections or memory.
    private void ApplyMemoryPanel()
    {
        var rows = MemoryRows;
        MemoryHeader.Visibility = rows > 0 ? Visibility.Visible : Visibility.Collapsed;
        MemoryToggleText.Text = Localizer.Get("ProfileMemory");
        MemoryChevron.Glyph = memoryOpen ? "" : "";
        AutomationProperties.SetName(MemoryToggle, Localizer.Get("ProfileMemory"));
        MemoryBorder.Visibility = rows > 0 && memoryOpen ? Visibility.Visible : Visibility.Collapsed;
        // The surface's margins and the border's edges, then the rows apart by their gaps.
        MemoryBorder.Height = 14 + rows * MemoryRowHeight + Math.Max(0, rows - 1) * MemoryRowGap;
    }

    private void MemoryToggle_Click(object sender, RoutedEventArgs e)
    {
        memoryOpen = !memoryOpen;
        ApplyMemoryPanel();
        RenderMemoryPanel();
    }

    private void MemorySurface_SizeChanged(object sender, SizeChangedEventArgs e) => RenderMemoryPanel();

    /// <summary>
    /// Heap on top, collections in the middle, video memory at the bottom, each on its own scale: the memory lines
    /// fitted to their lowest and highest reading in view, as their sizes differ too much for one scale and a fitted
    /// one shows small changes; the collections as bars from zero to the longest pause in view. Collections sit under
    /// the heap, whose drops they cause. The scale's ends stand at the left, in the row's colour.
    /// </summary>
    private void RenderMemoryPanel()
    {
        MemoryCanvas.Children.Clear();
        MemoryNames.Children.Clear();
        if (recording is null || MemoryBorder.Visibility != Visibility.Visible || MemorySurface.ActualWidth < 4) return;
        var width = MemorySurface.ActualWidth;
        var rows = new List<(Action<double, double> Draw, string Name, string Tip, Brush Brush)>();
        (string, string) Named(string key) => (Localizer.Get(key), Localizer.Get($"{key}Tip"));
        if (recording.Heap.Count > 0)
        {
            var (name, tip) = Named("ProfileMemoryHeapRow");
            rows.Add(((top, inner) => DrawLine(Visible(recording.Heap.Select(item => (item.Time, item.Used))), HeapBrush, top, inner),
                name, tip, HeapBrush));
        }
        if (recording.Collections.Count > 0)
        {
            var (name, tip) = Named("ProfileMemoryCollectionsRow");
            rows.Add((DrawCollections, name, tip, Muted));
        }
        // Under the collections: whether the mod's garbage comes just before them.
        if (AllocationOwner is { } owner)
            rows.Add(((top, inner) => DrawOwnerAllocation(owner.Key, top, inner), Localizer.Format("ProfileMemoryOwnerRowFormat", owner.Name),
                Localizer.Get("ProfileMemoryOwnerRowTip"), HighlightPath.Fill));
        if (recording.VideoMemory.Count > 0)
        {
            var (name, tip) = Named("ProfileMemoryVideoRow");
            rows.Add(((top, inner) => DrawLine(Visible(recording.VideoMemory.Select(item => (item.Time, item.Dedicated))), VideoBrush, top, inner),
                name, tip, VideoBrush));
        }
        // Rows apart by a gap, so one row's lowest label and the next one's highest do not meet.
        var rowHeight = (MemorySurface.ActualHeight - MemoryRowGap * (rows.Count - 1)) / Math.Max(1, rows.Count);
        for (var row = 0; row < rows.Count; row++)
        {
            var rowTop = row * (rowHeight + MemoryRowGap);
            if (row > 0)
            {
                var y = rowTop - MemoryRowGap / 2;
                MemoryCanvas.Children.Add(new Line { X1 = 0, X2 = width, Y1 = y, Y2 = y, Stroke = Muted, StrokeThickness = 0.5, Opacity = 0.6 });
            }
            // The drawing keeps clear of the row's edges by half a label, so each label centres on its end.
            var (draw, name, tip, brush) = rows[row];
            draw(rowTop + 6, Math.Max(1, rowHeight - 12));
            Name(name, tip, brush, rowTop);
        }
        UpdateSelectionRectangle();

        void DrawLine((long Time, long Value)[] points, Brush stroke, double top, double inner)
        {
            if (points.Length == 0) return;
            long low = points.Min(point => point.Value), high = points.Max(point => point.Value);
            // A flat line still needs a span; one percent of the value keeps it in the middle.
            var span = Math.Max(high - low, Math.Max(1, high / 100));
            var line = new Polyline { Stroke = stroke, StrokeThickness = 1.5, IsHitTestVisible = false };
            foreach (var (time, value) in points)
                line.Points.Add(new Windows.Foundation.Point(XAt(time), top + (1 - (value - low) / (double)span) * inner));
            MemoryCanvas.Children.Add(line);
            Labels(Bytes(high), Bytes(low), top, inner);
        }

        // Each collection as long as it paused the game and as tall as that pause against the longest one in view, so
        // a frame spike above a tall bar reads as "the game stopped to collect".
        void DrawCollections(double top, double inner)
        {
            var visible = recording.Collections.Where(item => item.Time < viewEnd && item.Time + item.Duration >= viewStart).ToArray();
            if (visible.Length == 0) return;
            var longest = Math.Max(1, visible.Max(item => item.Duration));
            // One shape for all bars: a game that allocates a lot collects many times a second.
            var bars = new GeometryGroup { FillRule = FillRule.Nonzero };
            foreach (var collection in visible)
            {
                var left = Math.Clamp(XAt(collection.Time), 0, Math.Max(0, width - 2));
                // A pause of a few milliseconds is far narrower than a pixel at most zooms: keep it visible.
                var barWidth = Math.Max(2, XAt(collection.Time + collection.Duration) - left);
                var barHeight = Math.Max(2, collection.Duration / (double)longest * inner);
                bars.Children.Add(new RectangleGeometry { Rect = new Rect(left, top + inner - barHeight, barWidth, barHeight) });
            }
            MemoryCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = bars, Fill = Muted });
            // Zero as the frame graph writes it.
            Labels(Milliseconds(longest / 1000.0), "0 ms", top, inner);
        }

        // The highlighted mod's allocations, one bar per three pixels, against the most it allocated in one of them.
        void DrawOwnerAllocation(string owner, double top, double inner)
        {
            var buckets = Math.Max(1, (int)(width / 3));
            var bytes = ProfileAnalysis.OwnerAllocationPerBucket(recording, viewStart, viewEnd, buckets, owner);
            var most = bytes.Max();
            if (most > 0)
            {
                var step = width / buckets;
                var bars = new GeometryGroup { FillRule = FillRule.Nonzero };
                for (var index = 0; index < buckets; index++)
                {
                    if (bytes[index] <= 0) continue;
                    var barHeight = Math.Max(1, bytes[index] / (double)most * inner);
                    bars.Children.Add(new RectangleGeometry { Rect = new Rect(index * step, top + inner - barHeight, Math.Max(1, step - 0.5), barHeight) });
                }
                MemoryCanvas.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = bars, Fill = HighlightPath.Fill });
            }
            Labels(Bytes(most), "0", top, inner);
        }

        // What the row is, as a small chip at its top left: a dot in the row's colour and the name in secondary text,
        // on an opaque background so a line passing under it does not cross the words. Resting the pointer on it says
        // how to read the row; presses and moves on it bubble to the graph, so a range can be dragged from it too.
        void Name(string text, string tip, Brush brush, double rowTop)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
            content.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = brush, VerticalAlignment = VerticalAlignment.Center });
            content.Children.Add(new TextBlock
            {
                Text = text, FontSize = 11,
                Foreground = SecondaryTextProbe.Background,
            });
            var chip = new Border
            {
                Background = SolidBaseProbe.Background,
                BorderBrush = CardStrokeProbe.Background, BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 0, 7, 1), Child = content,
            };
            AppToolTip.SetTip(chip, tip);
            Canvas.SetLeft(chip, 4);
            Canvas.SetTop(chip, rowTop - 2);
            MemoryNames.Children.Add(chip);
        }

        // The scale's ends in the margin, set against the graph like the frame graph's.
        void Labels(string high, string low, double top, double inner)
        {
            foreach (var (text, y) in new[] { (high, top - 7), (low, top + inner - 7) })
                MemoryCanvas.Children.Add(ScaleLabel(text, 10, y));
        }

        // The readings in view, with the last one before and the first one after, so the line meets both edges.
        (long Time, long Value)[] Visible(IEnumerable<(long Time, long Value)> all)
        {
            var list = all.ToList();
            var first = Math.Max(0, list.FindLastIndex(point => point.Time <= viewStart));
            var last = list.FindIndex(point => point.Time >= viewEnd);
            return list.GetRange(first, (last < 0 ? list.Count - 1 : last) - first + 1).ToArray();
        }
    }

    // A scale value in the graphs' left margin, its right edge a few pixels from the graph so values of any width line up.
    private TextBlock ScaleLabel(string text, double size, double top)
    {
        var label = new TextBlock { Text = text, FontSize = size, Foreground = Muted };
        label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        Canvas.SetLeft(label, -6 - label.DesiredSize.Width);
        Canvas.SetTop(label, top);
        return label;
    }

    // Memory readings are gigabytes; a function's allocations can be a few kilobytes. Two decimals in every unit.
    private static string Bytes(long bytes) =>
        bytes >= 1L << 30 ? (bytes / (double)(1L << 30)).ToString("N2", Localizer.Culture) + " GB"
        : bytes >= 1L << 20 ? (bytes / (double)(1L << 20)).ToString("N2", Localizer.Culture) + " MB"
        : (bytes / 1024.0).ToString("N2", Localizer.Culture) + " KB";

    private string CollectionText(int count, double pausedMilliseconds) =>
        $"{Localizer.Get("ProfileStatCollections")} {Localizer.Format("ProfileCollectionsValueFormat", count, Milliseconds(pausedMilliseconds))}";

    private Brush HeapBrush => SuccessProbe.Background;
    private Brush VideoBrush => PrimaryTextProbe.Background;

    /// <summary>Fills the figures on the line under the frames (absent ones hidden); returns those shown.</summary>
    private List<string> SetLaneInfo(string? collections, string? heap, string? video)
    {
        foreach (var (block, text) in new[] { (CollectionValue, collections), (HeapValue, heap), (VideoValue, video) })
        {
            block.Text = text ?? "";
            block.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        }
        return new[] { collections, heap, video }.OfType<string>().ToList();
    }

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
        // Fine steps: from 250 the next was 500, which left the top 40% of a 290 ms graph empty.
        foreach (var factor in new[] { 1.0, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 })
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
            SelectionRectangle.Visibility = MemorySelection.Visibility = Visibility.Collapsed;
            ZoomSelectionButton.IsEnabled = selectionStart is not null;
            return;
        }
        var left = Math.Max(0, XAt(start));
        var right = Math.Min(ChartWidth, XAt(end));
        // The same range on the frame graph and, when open, the memory graph.
        foreach (var (rectangle, height) in new[] { (SelectionRectangle, ChartHeight), (MemorySelection, MemorySurface.ActualHeight) })
        {
            Canvas.SetLeft(rectangle, left);
            Canvas.SetTop(rectangle, 0);
            rectangle.Width = Math.Max(2, right - left);
            rectangle.Height = Math.Max(1, height);
            rectangle.Visibility = Visibility.Visible;
        }
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
        // The frame graph or the memory graph: both share the time axis, so positions read the same.
        ((UIElement)sender).CapturePointer(e.Pointer);
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
        Canvas.SetLeft(MemoryHoverLine, Math.Clamp(x, 0, ChartWidth));
        MemoryHoverLine.Height = MemorySurface.ActualHeight;
        MemoryHoverLine.Visibility = Visibility.Visible;
        var frame = ProfileAnalysis.FrameAt(recording, time);
        List<(string?, string)> items = [(null, Seconds(time))];
        string? collection = null;
        if (frame is { } found && time >= found.Start)
        {
            items.Add((Localizer.Get("ProfileStatFrame"), Milliseconds(found.Duration / 1000.0)));
            // And how much of that frame the highlighted owner's code ran, the dark part of its bar.
            if (HighlightedOwner() is { } owner)
                items.Add((owner.Name, Milliseconds(ProfileAnalysis.OwnerTimeIn(recording, found.Start, found.Start + found.Duration,
                    owner.Java, owner.Key, recording.GameThread))));
            // Whether this frame was slow because the game stopped to collect garbage.
            var (collections, paused) = ProfileAnalysis.CollectionsIn(recording, found.Start, found.Start + found.Duration);
            if (collections > 0) collection = CollectionText(collections, paused);
        }
        SetStats(ChartInfo, items);
        // The lanes' figures follow the pointer too: this frame's collections, memory at this moment.
        var (heapNow, videoNow) = ProfileAnalysis.MemoryAt(recording, time);
        SetLaneInfo(collection,
            heapNow is { } heap ? $"{Localizer.Get("ProfileStatHeap")} {Bytes(heap.Used)}" : null,
            videoNow is { } video ? $"{Localizer.Get("ProfileStatVideo")} {Bytes(video.Dedicated)}" : null);
    }

    private void Chart_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (recording is null) return;
        var x = e.GetCurrentPoint(ChartSurface).Position.X;
        var wasSelecting = selecting;
        selecting = panning = false;
        ((UIElement)sender).ReleasePointerCapture(e.Pointer);
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
        HoverLine.Visibility = MemoryHoverLine.Visibility = Visibility.Collapsed;
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

    private void ProfilerPage_SizeChanged(object sender, SizeChangedEventArgs e) => ApplyLayout(e.NewSize.Width);

    private void ApplyLayout(double width)
    {
        // Narrow: the recording tools go below the title, and the functions below their owners.
        var narrowHeader = width < 760;
        Grid.SetRow(Toolbar, narrowHeader ? 1 : 0);
        Grid.SetColumn(Toolbar, narrowHeader ? 0 : 1);
        Grid.SetColumnSpan(Toolbar, narrowHeader ? 2 : 1);
        Toolbar.Margin = new Thickness(0, narrowHeader ? 0 : 9, 0, 0);
        var stacked = width < 720;
        // The owner list is as wide as the tabs over it need, at least 300: a third tab, or a language with long
        // names, would otherwise be cut off.
        ResultTabs.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        GroupColumn.Width = stacked ? new GridLength(1, GridUnitType.Star) : new GridLength(Math.Max(300, Math.Ceiling(ResultTabs.DesiredSize.Width)));
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

    private enum DetailKind { Lua, Java, Threads, Pauses, Allocation }
    private enum ResultTab { Lua, Java, Allocation }

    /// <summary>
    /// One entry of the owner list: a mod, the game's scripts, a part of the game code, the threads, the pauses. A mod
    /// in the allocation tab has its bytes instead of a share of time; its table comes from its call tree.
    /// </summary>
    private sealed record ResultGroup(string Key, string Name, double? Share, int Samples, DetailKind Kind,
        IReadOnlyList<ProfileShare> Rows, IReadOnlyList<ProfilePause> Pauses, long Bytes = 0);

    private ResultTab Tab =>
        ReferenceEquals(ResultTabs.SelectedItem, JavaTab) ? ResultTab.Java
        : ReferenceEquals(ResultTabs.SelectedItem, AllocationTab) ? ResultTab.Allocation : ResultTab.Lua;

    private SelectorBarItem TabItem => Tab switch { ResultTab.Java => JavaTab, ResultTab.Allocation => AllocationTab, _ => LuaTab };

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
        // A newer range makes the previous analysis pointless: stop it rather than let it finish on a worker.
        analysisCancel?.Cancel();
        var cancel = analysisCancel = new CancellationTokenSource();
        ProfileRange range;
        // Every row of a group, not the first few: the table shows the first and gathers the rest into one row with its sum.
        try { range = await Task.Run(() => ProfileAnalysis.Analyze(current, start, end, thread, MaximumGroupRows, cancel.Token), cancel.Token); }
        catch (Exception) { return; }
        finally { if (ReferenceEquals(analysisCancel, cancel)) analysisCancel = null; cancel.Dispose(); }
        if (version != analysisVersion || !ReferenceEquals(current, recording)) return;
        ShowRange(range);
    }

    private void ShowRange(ProfileRange range)
    {
        shown = range;
        if (HoverLine.Visibility == Visibility.Collapsed) ShowDefaultChartInfo();
        // A handful of samples cannot carry percentages; say so instead of showing confident numbers.
        FewSamplesInfo.IsOpen = range.Samples < 20;

        luaGroups = range.LuaGroups.Select(group => new ResultGroup(group.Key, OwnerName(group.Key),
            group.Self, group.Samples, DetailKind.Lua, group.Rows, [])).ToList();
        // The share only sizes the bar; the number shown is the bytes.
        allocationGroups = range.LuaAllocationGroups.Select(group => new ResultGroup(group.Key, OwnerName(group.Key),
            range.LuaAllocated > 0 ? (double)group.Self / range.LuaAllocated : 0, group.Samples, DetailKind.Allocation, [], [],
            group.Self)).ToList();
        javaGroups = range.MethodGroups.Select(group => new ResultGroup(group.Key, Localizer.Get($"ProfileGroup.{group.Key}"),
            group.Self, group.Samples, DetailKind.Java, group.Rows, [])).ToList();
        if (range.Threads.Count > 1)
            javaGroups.Add(new ResultGroup("#threads", Localizer.Get("ProfileThreadsSection"), null,
                range.Threads.Sum(row => row.Samples), DetailKind.Threads, range.Threads, []));
        if (range.LongestPauses.Count > 0)
            javaGroups.Add(new ResultGroup("#pauses", Localizer.Get("ProfilePausesSection"), null, 0, DetailKind.Pauses, [], range.LongestPauses));
        ShowTab();
    }

    private static string OwnerName(string key) =>
        key == ProfileAnalysis.GameOwner ? Localizer.Get("ProfileOwnerGame")
        : key == ProfileAnalysis.UnknownOwner ? Localizer.Get("ProfileOwnerUnknown") : key;

    private void ShowTab()
    {
        if (shown is not { } range) return;
        var tab = Tab;
        var java = tab == ResultTab.Java;
        listedGroups = tab switch { ResultTab.Java => javaGroups, ResultTab.Allocation => allocationGroups, _ => luaGroups };
        if (listedGroups.Count == 0)
        {
            SetSplitVisible(false);
            ResultMessage.Text = Localizer.Get(java ? "ProfileFewSamples" : recording?.LuaPeriod is not > 0 ? "ProfileNoLua"
                : tab == ResultTab.Allocation ? "ProfileAllocationNone" : "ProfileLuaNone");
            return;
        }
        SetSplitVisible(true);
        GroupNameHeading.Text = Localizer.Get(java ? "ProfileListJavaOwner" : "ProfileListLuaOwner");
        GroupShareText.Text = Localizer.Get(tab switch
        {
            ResultTab.Java => "ProfileListJavaShare", ResultTab.Allocation => "ProfileListAllocation", _ => "ProfileListLuaShare",
        });
        AppToolTip.SetTip(GroupShareHeading, tab switch
        {
            ResultTab.Java => Localizer.Get("ProfileListJavaShareTip"),
            // With the whole game thread's figure, which tells whether the scripts or the game's own code allocate more.
            ResultTab.Allocation => Localizer.Get("ProfileListAllocationTip") + (range.GameThreadAllocated is { } whole
                ? "\n" + Localizer.Format("ProfileAllocationGameThreadFormat", Bytes(whole)) : ""),
            _ => Localizer.Get("ProfileListLuaShareTip"),
        });
        // Only the scripts have a whole worth stating, beside the heading: the game code's items always add up to all of it.
        GroupShareTotal.Text = tab switch { ResultTab.Java => "", ResultTab.Allocation => Bytes(range.LuaAllocated), _ => FinePercent(range.LuaShare) };
        GroupShareTotal.Visibility = java ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(GroupShareHeading, java ? GroupShareText.Text : $"{GroupShareText.Text} {GroupShareTotal.Text}");
        // Bars are relative to the largest owner, so the list reads as a ranking; the number is the real share.
        var largest = listedGroups.Max(group => group.Share ?? 0);
        updatingGroups = true;
        GroupList.Items.Clear();
        highlightIcons.Clear();
        previewGroup = null;
        for (var position = 0; position < listedGroups.Count; position++)
            GroupList.Items.Add(GroupItem(listedGroups[position], largest, position));
        var remembered = tab switch { ResultTab.Java => javaSelection, ResultTab.Allocation => allocationSelection, _ => luaSelection };
        var index = Math.Max(0, listedGroups.FindIndex(group => group.Key == remembered));
        GroupList.SelectedIndex = index;
        updatingGroups = false;
        ShowGroup(listedGroups[index]);
        // Each tab has its own highlight, or none, and with it the memory panel's mod row.
        ApplyMemoryPanel();
        RenderChart();
    }

    private void GroupList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (updatingGroups || GroupList.SelectedIndex < 0 || GroupList.SelectedIndex >= listedGroups.Count) return;
        var group = listedGroups[GroupList.SelectedIndex];
        switch (Tab)
        {
            case ResultTab.Java: javaSelection = group.Key; break;
            case ResultTab.Allocation: allocationSelection = group.Key; break;
            default: luaSelection = group.Key; break;
        }
        ShowGroup(group);
        // A highlight follows the chosen owner (by keyboard too). The click of the same press must then keep it, not
        // take it for a second click on the highlighted owner: it is told so until this input is handled.
        if (Highlightable(group) && CurrentHighlight is { } highlighted && highlighted != group.Key)
        {
            SetHighlight(group.Key);
            highlightMovedTo = group.Key;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => highlightMovedTo = null);
        }
    }

    // ---- Highlight on the frame graph ----

    // The owner drawn over the frame graph in each tab, or none: clicking an owner in the list draws it, clicking it
    // again stops. A script owner also gets a row of its allocations in the memory panel; in the allocation tab that
    // row is the point, and the frame graph shows the same mod's time. A new recording starts with none.
    private string? luaHighlight, javaHighlight, allocationHighlight;
    // While one is highlighted, the owner under the pointer is drawn in its place until the pointer leaves.
    private ResultGroup? previewGroup;
    private string? highlightMovedTo;
    private readonly Dictionary<string, FontIcon> highlightIcons = [];

    private readonly record struct HighlightedGroup(bool Java, string Key, string Name);

    private static bool Highlightable(ResultGroup group) => group.Kind is DetailKind.Lua or DetailKind.Java or DetailKind.Allocation;

    private string? CurrentHighlight => Tab switch
    {
        ResultTab.Lua => luaHighlight, ResultTab.Java => javaHighlight, _ => allocationHighlight,
    };

    private HighlightedGroup? HighlightedOwner()
    {
        if (CurrentHighlight is not { } key) return null;
        if (previewGroup is { } preview && Highlightable(preview)) return new(preview.Kind == DetailKind.Java, preview.Key, preview.Name);
        var name = listedGroups.FirstOrDefault(group => group.Key == key)?.Name ?? key;
        return new(Tab == ResultTab.Java, key, name);
    }

    private void GroupList_ItemClick(object sender, ItemClickEventArgs e)
    {
        var index = GroupList.Items.IndexOf(e.ClickedItem);
        if (index < 0 || index >= listedGroups.Count || !Highlightable(listedGroups[index])) return;
        var key = listedGroups[index].Key;
        var next = highlightMovedTo == key || CurrentHighlight != key ? key : null;
        highlightMovedTo = null;
        SetHighlight(next);
    }

    private void SetHighlight(string? key)
    {
        switch (Tab)
        {
            case ResultTab.Java: javaHighlight = key; break;
            case ResultTab.Allocation: allocationHighlight = key; break;
            default: luaHighlight = key; break;
        }
        previewGroup = null;
        UpdateHighlightIcons();
        // The memory panel gains or loses the mod's row.
        ApplyMemoryPanel();
        RenderChart();
    }

    private void UpdateHighlightIcons()
    {
        var current = CurrentHighlight;
        foreach (var (key, icon) in highlightIcons) icon.Visibility = key == current ? Visibility.Visible : Visibility.Collapsed;
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
        // No tip but the full name, and that only where the screen cuts it short: the samples stand above the table.
        var nameText = new TextBlock { Text = group.Name, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        nameText.IsTextTrimmedChanged += (_, _) => AppToolTip.SetTip(nameText, nameText.IsTextTrimmed ? group.Name : null);
        item.Children.Add(nameText);
        var value = new TextBlock { Text = ValueOf(group), Foreground = Muted };
        // The number, and before it a small graph mark while the owner is drawn over the frame graph.
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (Highlightable(group))
        {
            var mark = new FontIcon
            {
                Glyph = "", FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
                Foreground = HighlightPath.Fill,
                Visibility = group.Key == CurrentHighlight ? Visibility.Visible : Visibility.Collapsed,
            };
            highlightIcons[group.Key] = mark;
            trailing.Children.Add(mark);
            // While one owner is highlighted, pointing at another draws it instead, to compare without clicking.
            item.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            item.PointerEntered += (_, _) =>
            {
                if (CurrentHighlight is not { } current || current == group.Key || previewGroup == group) return;
                previewGroup = group;
                RenderChart();
            };
            item.PointerExited += (_, _) =>
            {
                if (previewGroup != group) return;
                previewGroup = null;
                RenderChart();
            };
        }
        trailing.Children.Add(value);
        Grid.SetColumn(trailing, 1);
        item.Children.Add(trailing);
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
        // How the highlight works is in the graph's help, not repeated on every row the pointer crosses.
        AutomationProperties.SetName(item, group.Name + (value.Text.Length > 0 ? ", " + value.Text : ""));
        return item;
    }

    /// <summary>The number beside an owner: its share, or for the pauses how many there were, with a unit so it is not read as a share.</summary>
    private static string ValueOf(ResultGroup group) =>
        group.Kind == DetailKind.Allocation ? Bytes(group.Bytes)
        : group.Share is { } share ? FinePercent(share)
        : group.Kind == DetailKind.Pauses ? Localizer.Format("ProfilePauseCount", group.Pauses.Count.ToString("N0", Localizer.Culture)) : "";

    /// <summary>The right pane: the chosen owner's functions as a table with a heading over every column.</summary>
    private void ShowGroup(ResultGroup group)
    {
        // Above the table, outside it: whose functions these are and its samples out of the tab's.
        // Its share is not repeated here; the list beside shows it.
        DetailName.Text = group.Name;
        AppToolTip.SetTip(DetailName, group.Name);
        SetStats(DetailSamples, SamplesOf(group) is { } samples ? [(Localizer.Get("ProfileColumnSamples"), samples)] : []);
        shownGroup = group;
        var tree = TreeOf(group);
        CallTreeToggle.Visibility = tree is null ? Visibility.Collapsed : Visibility.Visible;
        CallTreeToggle.IsOn = callTree;

        var (columns, header, rows) = Table(group);
        DetailHeader.Child = TableRow(columns, header, header: true);
        DetailRows.Children.Clear();
        foreach (var line in rows)
            DetailRows.Children.Add(line.Tree is { } item ? TreeRow(columns, group, line, item)
                : TableRow(columns, line.Cells, header: false, line.Bar, line.SelfBar));
    }

    /// <summary>
    /// One line of a table: its cells as text (what a copy carries), how full the bar behind its total is (0..1, or none),
    /// and for a call tree the node it shows.
    /// </summary>
    private sealed record TableLine((string Text, string? Tip, bool Right)[] Cells, double? Bar = null, TreeItem? Tree = null,
        double? SelfBar = null);

    // ---- Call tree ----

    // Tree or list, for as long as the app runs, in both script tabs. The tree first, closed: its outermost functions
    // add up to the owner, and opening the heavy one is the next question.
    private static bool callTree = true;
    private ResultGroup? shownGroup;
    // The open nodes of each tab's owner, by path; a new range keeps them, a new recording starts over.
    private readonly Dictionary<string, HashSet<string>> openPaths = [];
    // A tree opened all the way down can be long; past this the rest is left closed.
    private const int MaximumTreeRows = 400;
    // Siblings past this many, and list rows past RowsPerGroup, are gathered under one closed "the rest" line that
    // carries their sum: the parts on screen then visibly add up to the whole, and the long tail stays one click away.
    private const int MaximumSiblings = 20;

    /// <summary>
    /// A line of the tree: a node, or (with <see cref="Rest"/>) the siblings past the first few, gathered and summed;
    /// opened, they follow it one level deeper.
    /// </summary>
    private sealed record TreeItem(ProfileCallNode? Node, int Depth, string Path, bool HasChildren, bool Open,
        IReadOnlyList<ProfileCallNode>? Rest = null);

    private ProfileCallNode? TreeOf(ResultGroup group) =>
        group.Kind is DetailKind.Lua or DetailKind.Allocation && shown?.LuaCallTrees.TryGetValue(group.Key, out var tree) == true ? tree : null;

    private void CallTreeToggle_Toggled(object sender, RoutedEventArgs e)
    {
        // Showing an owner sets the switch to the remembered choice; that is not a change to act on.
        if (CallTreeToggle.IsOn == callTree) return;
        callTree = CallTreeToggle.IsOn;
        if (shownGroup is { } group) ShowGroup(group);
    }

    // In the allocation tab, a path that allocated nothing is left out and the heaviest in bytes comes first.
    private static IEnumerable<ProfileCallNode> Branches(ProfileCallNode node, bool allocation) =>
        allocation ? node.Children.Where(child => child.AllocatedTotal > 0).OrderByDescending(child => child.AllocatedTotal) : node.Children;

    /// <summary>The rows the tree shows: every open node's children, in order. All closed at first.</summary>
    private List<TreeItem> TreeRows(ResultGroup group, ProfileCallNode root)
    {
        var allocation = group.Kind == DetailKind.Allocation;
        var key = $"{group.Kind}|{group.Key}";
        if (!openPaths.TryGetValue(key, out var open)) openPaths[key] = open = [];
        var rows = new List<TreeItem>();
        void Add(ProfileCallNode child, int depth, string path)
        {
            if (rows.Count >= MaximumTreeRows) return;
            var childPath = path + "/" + child.Function;
            var hasChildren = Branches(child, allocation).Any();
            var isOpen = hasChildren && open.Contains(childPath);
            rows.Add(new TreeItem(child, depth, childPath, hasChildren, isOpen));
            if (isOpen) Walk(child, depth + 1, childPath);
        }
        void Walk(ProfileCallNode node, int depth, string path)
        {
            var branches = Branches(node, allocation).ToList();
            foreach (var child in branches.Take(MaximumSiblings)) Add(child, depth, path);
            if (branches.Count <= MaximumSiblings || rows.Count >= MaximumTreeRows) return;
            var rest = branches.Skip(MaximumSiblings).ToList();
            var restPath = path + "/*";
            var restOpen = open.Contains(restPath);
            rows.Add(new TreeItem(null, depth, restPath, true, restOpen, rest));
            if (restOpen) foreach (var child in rest) Add(child, depth + 1, path);
        }
        Walk(root, 0, "");
        return rows;
    }

    /// <summary>
    /// A script function's line, in the tree or the list. Its numbers are parts of the owner, the owner being 100%: the
    /// question here is where inside it the time or the bytes went, and parts of the whole range shrank to 0.0% in a
    /// long one. The bar behind the total says the same at a glance. What the part is of the whole range, and as time,
    /// is one hover away, so a large part of a light owner is not mistaken for a heavy one.
    /// </summary>
    private TableLine FunctionLine(ProfileCallNode owner, bool allocation, string name, string file, int selfSamples, int samples,
        int shownSamples, long allocatedSelf, long allocatedTotal, string indent = "", TreeItem? tree = null)
    {
        (string, string?, bool) Part(int part, long bytes)
        {
            if (allocation)
            {
                var share = owner.AllocatedTotal > 0 ? (double)bytes / owner.AllocatedTotal : 0;
                return (Bytes(bytes), Localizer.Format("ProfileShareOfOwnerFormat", FinePercent(share)), true);
            }
            // The owner's samples stand for its share of the range, so each of them for an equal slice of it.
            var ofRange = owner.Samples > 0 ? owner.Total * part / owner.Samples : 0;
            var micros = ofRange * Math.Max(1, (shown?.End ?? 0) - (shown?.Start ?? 0));
            var time = micros >= 1_000_000 ? Seconds((long)micros) : Milliseconds(micros / 1000);
            return (FinePercent(owner.Samples > 0 ? (double)part / owner.Samples : 0),
                Localizer.Format("ProfileShareOfRangeFormat", FinePercent(ofRange), time), true);
        }
        var whole = allocation ? owner.AllocatedTotal : owner.Samples;
        var filled = allocation ? allocatedTotal : samples;
        // How much of the line's own total is its own work, the rest being what it called: 100% is a leaf's.
        double own = allocation ? allocatedSelf : selfSamples, all = allocation ? allocatedTotal : samples;
        // Its share of the owner for now; the table scales the bars to its largest line once all are known.
        return new TableLine(
        [
            (indent + name, name, false), (LuaFileName(file), file, false),
            Part(selfSamples, allocatedSelf), Part(samples, allocatedTotal),
            (shownSamples.ToString("N0", Localizer.Culture), null, true),
        ], whole > 0 ? Math.Clamp((double)filled / whole, 0, 1) : 0, tree, all > 0 ? Math.Clamp(own / all, 0, 1) : 0);
    }

    /// <summary>
    /// The line that stands for the rest of a level: how many, and their sums. Its total is left empty where the rows
    /// overlap (a list's functions call one another, so their totals do not add up); a tree's siblings never do.
    /// </summary>
    private TableLine RestLine(ProfileCallNode owner, bool allocation, int count, int selfSamples, int samples, int shownSamples,
        long allocatedSelf, long allocatedTotal, bool totals, string indent, TreeItem? tree)
    {
        var line = FunctionLine(owner, allocation, Localizer.Format("ProfileRestFormat", count.ToString("N0", Localizer.Culture)), "",
            selfSamples, samples, shownSamples, allocatedSelf, allocatedTotal, indent, tree);
        if (!totals) line.Cells[TotalColumn] = ("", null, true);
        // No bars: a sum of many is no line of its own to compare.
        return line with { Bar = null, SelfBar = null };
    }

    private Grid TreeRow(IReadOnlyList<GridLength> columns, ResultGroup group, TableLine line, TreeItem item)
    {
        var row = TableRow(columns, line.Cells, header: false, line.Bar, line.SelfBar);
        // The name cell gives way to an indented one with the open/close arrow in front.
        row.Children.RemoveAt(0);
        var name = new Grid { Margin = new Thickness(item.Depth * 16, 0, 0, 0), ColumnSpacing = 2 };
        name.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        name.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (item.HasChildren)
        {
            var arrow = new Button
            {
                Width = 20, Height = 20, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center,
                Style = (Style)Application.Current.Resources["SubtleButtonStyle"],
                Content = new FontIcon { Glyph = item.Open ? "" : "", FontSize = 10 },
            };
            AutomationProperties.SetName(arrow, Localizer.Get(item.Open ? "ProfileTreeCollapse" : "ProfileTreeExpand") + " " + line.Cells[0].Text.Trim());
            arrow.Click += (_, _) => ToggleNode(group, item.Path);
            name.Children.Add(arrow);
            // The whole row opens and closes too, not only the small arrow; a tap on the arrow is its click's.
            row.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            row.Tapped += (_, args) =>
            {
                for (var element = args.OriginalSource as DependencyObject; element is not null; element = VisualTreeHelper.GetParent(element))
                    if (ReferenceEquals(element, arrow)) return;
                ToggleNode(group, item.Path);
            };
        }
        // A node by its name; the rest of a level muted, as it is no function.
        var label = line.Cells[0].Text.Trim();
        var text = new TextBlock { Text = label, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        if (item.Node is null) text.Foreground = Muted;
        // The full name only where the screen cuts it short; a name shown whole needs no tip repeating it.
        else text.IsTextTrimmedChanged += (_, _) => AppToolTip.SetTip(text, text.IsTextTrimmed ? label : null);
        Grid.SetColumn(text, 1);
        name.Children.Add(text);
        row.Children.Insert(0, name);
        return row;
    }

    private void ToggleNode(ResultGroup group, string path)
    {
        // A list's "rest" row can be opened before the owner's tree was ever shown.
        var key = $"{group.Kind}|{group.Key}";
        if (!openPaths.TryGetValue(key, out var open)) openPaths[key] = open = [];
        if (!open.Remove(path)) open.Add(path);
        ShowGroup(group);
    }

    /// <summary>An owner's samples out of its tab's, such as "9/70", or null for an owner that has none.</summary>
    private string? SamplesOf(ResultGroup group)
    {
        if (group.Samples <= 0) return null;
        // The threads are every thread's samples, not a part of the chosen thread's: their count alone.
        if (group.Kind == DetailKind.Threads) return group.Samples.ToString("N0", Localizer.Culture);
        var total = group.Kind is DetailKind.Lua or DetailKind.Allocation ? shown?.LuaSamples ?? 0 : shown?.Samples ?? 0;
        return $"{group.Samples.ToString("N0", Localizer.Culture)}/{total.ToString("N0", Localizer.Culture)}";
    }

    /// <summary>
    /// One owner's table: its columns, their headings and its rows. A cell's tip is its full text where the
    /// screen shows less (a method's package, a script's path), which is also what a copy carries.
    /// </summary>
    private (GridLength[] Columns, (string Text, string? Tip, bool Right)[] Header, List<TableLine> Rows) Table(ResultGroup group)
    {
        GridLength Star(double weight) => new(weight, GridUnitType.Star);
        GridLength Fixed(double width) => new(width);
        // Wide enough for "1,023.99 KB"; the total's column also holds the bar behind its number.
        var numbers = new[] { Fixed(84), Fixed(96), Fixed(60) };
        var columns = group.Kind switch
        {
            DetailKind.Lua or DetailKind.Allocation or DetailKind.Java => [Star(3), Star(2), .. numbers],
            DetailKind.Pauses => [Fixed(90), Fixed(90), Star(1), Star(2)],
            _ => (GridLength[])[Star(1), .. numbers],
        };
        var tree = TreeOf(group);
        // Each heading its own tip; a script owner's parts are of the owner, and its samples mean what the view counts.
        var (selfTip, totalTip) = group.Kind switch
        {
            DetailKind.Allocation => ("ProfileAllocationSelfTip", "ProfileAllocationTotalTip"),
            DetailKind.Lua when tree is not null => ("ProfileLuaSelfTip", "ProfileLuaTotalTip"),
            DetailKind.Java => ("ProfileJavaSelfTip", "ProfileJavaTotalTip"),
            _ => ("ProfileColumnSelfTip", "ProfileColumnTotalTip"),
        };
        var samplesTip = group.Kind == DetailKind.Java ? Localizer.Get("ProfileColumnSamplesListTip")
            : tree is null ? null : Localizer.Get(callTree ? "ProfileColumnSamplesTreeTip" : "ProfileColumnSamplesListTip");
        (string, string?, bool)[] Numbers() =>
        [
            (Localizer.Get("ProfileColumnSelf"), Localizer.Get(selfTip), true),
            (Localizer.Get("ProfileColumnTotal"), Localizer.Get(totalTip), true),
            (Localizer.Get("ProfileColumnSamples"), samplesTip, true),
        ];
        (string Text, string? Tip, bool Right)[] header = group.Kind switch
        {
            DetailKind.Lua or DetailKind.Allocation =>
                [(Localizer.Get("ProfileColumnFunction"), null, false), (Localizer.Get("ProfileColumnFile"), null, false), .. Numbers()],
            DetailKind.Java => [(Localizer.Get("ProfileColumnMethod"), null, false), (Localizer.Get("ProfileColumnPackage"), null, false), .. Numbers()],
            DetailKind.Threads => [(Localizer.Get("ProfileColumnThread"), null, false), .. Numbers()],
            _ =>
            [
                (Localizer.Get("ProfileColumnTime"), null, false), (Localizer.Get("ProfileColumnLength"), null, true),
                (Localizer.Get("ProfileColumnKind"), null, false), (Localizer.Get("ProfileColumnDetail"), null, false),
            ],
        };
        var rows = new List<TableLine>();
        if (group.Kind == DetailKind.Pauses)
        {
            foreach (var pause in group.Pauses)
            {
                var detail = string.Join(" · ", new[]
                {
                    pause.Detail is "?" or "" ? null : pause.Detail,
                    pause.Thread >= 0 && recording is not null && pause.Thread < recording.Threads.Count ? recording.Threads[pause.Thread] : null,
                }.OfType<string>());
                rows.Add(new(
                [
                    (Seconds(pause.Time), null, false), (Milliseconds(pause.Duration / 1000.0), null, true),
                    (pause.Kind, null, false), (detail, detail, false),
                ]));
            }
            return (columns, header, rows);
        }
        // A script owner: its call tree, or the tree's functions added up, from the same samples either way. In the
        // allocation tab what allocated nothing is left out and the most bytes come first.
        if (tree is not null)
        {
            var allocation = group.Kind == DetailKind.Allocation;
            if (callTree)
                foreach (var item in TreeRows(group, tree))
                {
                    // As text each name is indented by its depth, the open paths only, as on screen.
                    var indent = new string(' ', item.Depth * 2);
                    if (item.Rest is { } rest)
                        rows.Add(RestLine(tree, allocation, rest.Count, rest.Sum(node => node.SelfSamples), rest.Sum(node => node.Samples),
                            rest.Sum(node => node.Samples), rest.Sum(node => node.AllocatedSelf), rest.Sum(node => node.AllocatedTotal),
                            totals: true, indent, item));
                    else if (item.Node is { } node)
                        rows.Add(FunctionLine(tree, allocation, node.Name, node.File, node.SelfSamples, node.Samples, node.Samples,
                            node.AllocatedSelf, node.AllocatedTotal, indent, item));
                }
            else
            {
                var functions = ProfileAnalysis.FunctionsIn(tree);
                if (allocation)
                    functions = functions.Where(row => row.AllocatedTotal > 0).OrderByDescending(row => row.AllocatedSelf)
                        .ThenByDescending(row => row.AllocatedTotal).ToArray();
                // The list counts the samples that ended in each function, as it always has.
                TableLine Line(ProfileFunctionTotal row, string indent = "") => FunctionLine(tree, allocation, row.Name, row.File,
                    row.SelfSamples, row.Samples, row.SelfSamples, row.AllocatedSelf, row.AllocatedTotal, indent);
                foreach (var row in functions.Take(RowsPerGroup)) rows.Add(Line(row));
                if (functions.Count > RowsPerGroup)
                {
                    var rest = functions.Skip(RowsPerGroup).ToArray();
                    var path = "list/*";
                    var restOpen = openPaths.TryGetValue($"{group.Kind}|{group.Key}", out var open) && open.Contains(path);
                    rows.Add(RestLine(tree, allocation, rest.Length, rest.Sum(row => row.SelfSamples), rest.Sum(row => row.Samples),
                        rest.Sum(row => row.SelfSamples), rest.Sum(row => row.AllocatedSelf), rest.Sum(row => row.AllocatedTotal),
                        totals: false, "", new TreeItem(null, 0, path, true, restOpen)));
                    if (restOpen) foreach (var row in rest) rows.Add(Line(row, "  "));
                }
            }
            ScaleBars(rows);
            return (columns, header, rows);
        }
        if (group.Kind == DetailKind.Java)
        {
            // Like a script owner's list: the group is 100%, gauges behind the numbers, the long tail in one closed row.
            foreach (var row in group.Rows.Take(RowsPerGroup)) rows.Add(MethodLine(group, row));
            if (group.Rows.Count > RowsPerGroup)
            {
                var rest = group.Rows.Skip(RowsPerGroup).ToArray();
                var path = "list/*";
                var restOpen = openPaths.TryGetValue($"{group.Kind}|{group.Key}", out var open) && open.Contains(path);
                var whole = group.Share ?? 0;
                var self = rest.Sum(row => row.Self);
                // Its total is left empty: the methods call one another, so their totals do not add up.
                rows.Add(new(
                [
                    (Localizer.Format("ProfileRestFormat", rest.Length.ToString("N0", Localizer.Culture)), null, false), ("", null, false),
                    (FinePercent(whole > 0 ? self / whole : 0), Localizer.Format("ProfileShareOfRunFormat", FinePercent(self)), true), ("", null, true),
                    (rest.Sum(row => row.Samples).ToString("N0", Localizer.Culture), null, true),
                ], Tree: new TreeItem(null, 0, path, true, restOpen)));
                if (restOpen) foreach (var row in rest) rows.Add(MethodLine(group, row, "  "));
            }
            ScaleBars(rows);
            return (columns, header, rows);
        }
        foreach (var row in group.Rows)
            rows.Add(new([(row.Name, row.Name, false), (FinePercent(row.Self), null, true), (FinePercent(row.Total), null, true),
                (row.Samples.ToString("N0", Localizer.Culture), null, true)]));
        return (columns, header, rows);
    }

    // Bars against the table's largest total, so the heaviest line fills its column and the rest compare to it.
    private static void ScaleBars(List<TableLine> rows)
    {
        var largest = rows.Count == 0 ? 0 : rows.Max(line => line.Bar ?? 0);
        if (largest <= 0) return;
        for (var index = 0; index < rows.Count; index++)
            if (rows[index].Bar is { } bar) rows[index] = rows[index] with { Bar = bar / largest };
    }

    /// <summary>
    /// A method's line in a part of the game code: its parts of the group, the group being 100%, with what they are of all
    /// the running time one hover away; the self gauge is its own part of its total, as in the script tables.
    /// </summary>
    private static TableLine MethodLine(ResultGroup group, ProfileShare row, string indent = "")
    {
        var whole = group.Share ?? 0;
        (string, string?, bool) Part(double share) =>
            (FinePercent(whole > 0 ? share / whole : 0), Localizer.Format("ProfileShareOfRunFormat", FinePercent(share)), true);
        var package = PackageOf(row.Name);
        return new TableLine(
        [
            (indent + ShortMethod(row.Name), row.Name, false), (package, package, false),
            Part(row.Self), Part(row.Total), (row.Samples.ToString("N0", Localizer.Culture), null, true),
        ], whole > 0 ? Math.Clamp(row.Total / whole, 0, 1) : 0, null, row.Total > 0 ? Math.Clamp(row.Self / row.Total, 0, 1) : 0);
    }

    // "zombie.iso.IsoCell.render" is in "zombie.iso"; the class and method are the name's column.
    private static string PackageOf(string method)
    {
        var last = method.LastIndexOf('.');
        var previous = last <= 0 ? -1 : method.LastIndexOf('.', last - 1);
        return previous <= 0 ? "" : method[..previous];
    }

    /// <param name="bar">How full the gauge behind the total is (0..1), for a script function; none elsewhere.</param>
    /// <param name="selfBar">How full the gauge behind the self figure is: the line's own part of its total.</param>
    private Grid TableRow(IReadOnlyList<GridLength> columns, IReadOnlyList<(string Text, string? Tip, bool Right)> cells, bool header,
        double? bar = null, double? selfBar = null)
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
            // A script table's number headings stand over their numbers, which sit inset in their gauges.
            if (header && cells.Count == 5 && index is SelfColumn or TotalColumn) cell.Padding = new Thickness(0, 0, 6, 0);
            if (tip is { Length: > 0 } && (header || tip != text)) AppToolTip.SetTip(cell, tip);
            Grid.SetColumn(cell, index);
            // Gauges behind the numbers: a faint track the width of the column, so the number always sits in it, and a
            // fill in exact proportion (a fill never shorter than its number made a thousandth look like the whole).
            // The total's is its part against the table's largest, so heavy lines stand out before any number is read;
            // the self figure's, muted as it measures something else, is the line's own work against its total.
            var gauge = index switch { TotalColumn => bar, SelfColumn => selfBar, _ => null };
            if (gauge is { } fraction && columns[index].IsAbsolute)
            {
                cell.Padding = new Thickness(0, 0, 6, 0);
                var color = index == TotalColumn ? (BarsPath.Fill as SolidColorBrush)?.Color ?? Microsoft.UI.Colors.SteelBlue
                    : (Muted as SolidColorBrush)?.Color ?? Microsoft.UI.Colors.Gray;
                var track = new Border
                {
                    Margin = new Thickness(0, -3, 0, -3), CornerRadius = new CornerRadius(3),
                    Background = new SolidColorBrush(color) { Opacity = 0.07 },
                    Child = new Border
                    {
                        Width = Math.Clamp(fraction, 0, 1) * columns[index].Value, HorizontalAlignment = HorizontalAlignment.Left,
                        CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(color) { Opacity = 0.3 },
                    },
                };
                Grid.SetColumn(track, index);
                row.Children.Add(track);
            }
            row.Children.Add(cell);
        }
        return row;
    }

    // The numbers' places in a script function's line: name, file, self, total, samples.
    private const int SelfColumn = 2, TotalColumn = 3;

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
        text.AppendLine(TabItem.Text);
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
            all.AddRange(rows.Select(line => line.Cells));
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

    // Two decimals everywhere, the owner list's shares as the tables' parts: small ones must still add up visibly.
    private static string FinePercent(double share) => (share * 100).ToString("0.00", Localizer.Culture) + "%";

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
