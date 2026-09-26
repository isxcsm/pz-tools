using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using PzTools.Projections;
using PzTools.App.Core;

namespace PzTools.App;

public sealed partial class LogsPage
{
    private LogLevel minimumLevel = LogLevel.Warning;
    private LogLevel recordMinimum = LogLevel.Information;
    private string componentCategory = "All";
    private LogNumberRange? logRange;
    private LogNumberRange? runRange;
    private LogTimeRange? timeRange;
    private string timeFromText = "", timeThroughText = "";
    private FlyoutBase? filterFlyout;
    private Action<bool>? stopFilterEdit;
    private static readonly string[] Categories = ["All", "Backup", "Restore", "Recovery", "Archive", "State", "Schedule", "Maintenance", "Other"];

    private static string CategoryLabel(string category) => Localizer.Get(category switch
    {
        "All" => "All",
        "Recovery" => "LogActivity.CharacterRecovery",
        _ => $"LogComponent.{category}",
    });

    private void LocalizeFilterHeaders()
    {
        DismissFilterEditor(commitPending: true);
        LogNumberHeader.Text = Localizer.Get("LogNumberHeader");
        LogLevelHeader.Text = Localizer.Get("LogLevelHeader");
        LogTimeHeader.Text = Localizer.Format("LogTimeHeaderFormat", LogTimeFormatter.ShortZoneName);
        LogMessageHeader.Text = Localizer.Get("LogMessageHeader");
        LogRunHeader.Text = Localizer.Get("LogRunHeader");
        HeaderHint(LogNumberButton, LogNumberHeader.Text);
        HeaderHint(LogTimeButton, LogTimeHeader.Text);
        HeaderHint(LogMessageButton, Localizer.Get("LogComponentFilter"));
        HeaderHint(LogRunButton, Localizer.Get("LogRunIndexFilter"));
        UpdateFilterChips();
    }

    private static void HeaderHint(Button button, string label)
    {
        var hint = Localizer.Format("LogFilterHeaderHint", label);
        AppToolTip.SetTip(button, hint);
        AutomationProperties.SetName(button, hint);
    }

    private async Task FiltersChangedAsync()
    {
        UpdateFilterChips();
        pageIndex = 0;
        pageSnapshot = 0;
        await LoadPageAsync(resetSnapshot: true);
    }

    private void CloseFiltersAndQueries()
    {
        DismissFilterEditor(commitPending: true);
        filterFlyout = null;
        ++queryVersion;
        pageQueryCancellation?.Cancel();
    }

    private void UpdateFilterChips()
    {
        LogLevelHeader.Text = Localizer.Get($"LogLevel.{minimumLevel}");
        var level = Localizer.Format("LogLevelAtOrAboveFormat", LogLevelHeader.Text);
        var hint = Localizer.Format("LogLevelCycleHint", level);
        AppToolTip.SetTip(LogLevelButton, hint);
        AutomationProperties.SetName(LogLevelButton, hint);
        FilterChips.Children.Clear();
        AddChip(logRange is not null, LogNumberHeader.Text, logRange?.ToString() ?? "", () => logRange = null);
        AddChip(minimumLevel > recordMinimum, Localizer.Get("LogLevelHeader"), level,
            () => { minimumLevel = recordMinimum; levelChosenByUser = true; });
        AddChip(timeRange is not null, LogTimeHeader.Text,
            $"{(timeFromText.Length == 0 ? "…" : timeFromText)} – {(timeThroughText.Length == 0 ? "…" : timeThroughText)}", ClearTime);
        AddChip(componentCategory != "All", Localizer.Get("LogComponentFilter"), CategoryLabel(componentCategory), () => componentCategory = "All");
        AddChip(runRange is not null, Localizer.Get("LogRunIndexFilter"), runRange?.ToString() ?? "", () => runRange = null);
        ActiveFilters.Visibility = FilterChips.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (FilterChips.Children.Count == 0) return;
        var clearAll = new Button { Content = Localizer.Get("LogFiltersClearAll"), Style = (Style)Resources["LogPageButtonStyle"] };
        clearAll.Click += async (_, _) =>
        {
            DismissFilterEditor(commitPending: false);
            logRange = runRange = null;
            componentCategory = "All";
            minimumLevel = recordMinimum;
            levelChosenByUser = true;
            ClearTime();
            await FiltersChangedAsync();
            LogNumberButton.Focus(FocusState.Programmatic);
        };
        FilterChips.Children.Add(clearAll);

        void AddChip(bool active, string label, string value, Action clear)
        {
            if (!active) return;
            var text = $"{label}: {value} ×";
            var chip = new Button
            {
                Content = new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 300, FontSize = 11 },
                Style = (Style)Resources["LogPageButtonStyle"],
            };
            var remove = $"{Localizer.Get("LogFilterClear")}: {label}: {value}";
            AppToolTip.SetTip(chip, remove);
            AutomationProperties.SetName(chip, remove);
            chip.Click += async (_, _) =>
            {
                DismissFilterEditor(commitPending: false);
                clear();
                await FiltersChangedAsync();
                LogNumberButton.Focus(FocusState.Programmatic);
            };
            FilterChips.Children.Add(chip);
        }
    }

    private void ClearTime() { timeRange = null; timeFromText = timeThroughText = ""; }
    private void LogNumberButton_Click(object sender, RoutedEventArgs e) => ShowNumberFilter(LogNumberButton, false);
    private void LogRunButton_Click(object sender, RoutedEventArgs e) => ShowNumberFilter(LogRunButton, true);

    private async void LogLevelButton_Click(object sender, RoutedEventArgs e)
    {
        DismissFilterEditor(commitPending: true);
        var levels = Enum.GetValues<LogLevel>().Where(level => level >= recordMinimum).ToArray();
        minimumLevel = levels[(Array.IndexOf(levels, minimumLevel) + 1) % levels.Length];
        levelChosenByUser = true;
        await FiltersChangedAsync();
    }

    private void ShowNumberFilter(Button anchor, bool operation)
    {
        DismissFilterEditor(commitPending: true);
        var input = new TextBox
        {
            Header = Localizer.Get(operation ? "LogRunIndexFilter" : "LogNumberHeader"),
            Text = (operation ? runRange : logRange)?.ToString() ?? "", PlaceholderText = "42 / 40-50",
        };
        var content = new StackPanel { Width = 280, Spacing = 10 };
        content.Children.Add(input);
        content.Children.Add(Hint("LogNumberRangeHint"));
        var error = ErrorText("LogNumberRangeInvalid"); content.Children.Add(error);
        ShowLiveEditor(anchor, content, [input], () =>
        {
            var valid = LogNumberRange.TryParse(input.Text, out var range);
            error.Visibility = valid ? Visibility.Collapsed : Visibility.Visible;
            if (!valid || range == (operation ? runRange : logRange)) return false;
            if (operation) runRange = range; else logRange = range;
            return true;
        });
    }

    private void LogTimeButton_Click(object sender, RoutedEventArgs e)
    {
        DismissFilterEditor(commitPending: true);
        var now = DateTimeOffset.Now;
        var initial = timeRange is null ? LogTimeFilterDraft.RecentDay(now, TimeZoneInfo.Local)
            : new LogTimeFilterDraft(timeFromText, timeThroughText);
        var from = new TextBox { Text = initial.FromText, PlaceholderText = "yyyy-MM-dd HH:mm", MinWidth = 0 };
        var through = new TextBox { Text = initial.ThroughText, PlaceholderText = "yyyy-MM-dd HH:mm", MinWidth = 0 };
        var content = new StackPanel { Width = 340, Spacing = 12 };
        content.Children.Add(new TextBlock { Text = Localizer.Format("LogLocalTimeHint", LogTimeFormatter.ShortZoneName), TextWrapping = TextWrapping.Wrap });
        var recent = new Button { Content = Localizer.Get("LogTimeRecentDay"), Style = (Style)Resources["LogPageButtonStyle"] };
        Action applySelection = () => { };
        recent.Click += (_, _) =>
        {
            var draft = LogTimeFilterDraft.RecentDay(DateTimeOffset.Now, TimeZoneInfo.Local);
            from.Text = draft.FromText; through.Text = draft.ThroughText;
            applySelection();
        };
        content.Children.Add(recent);
        content.Children.Add(CreateTimeInput(from, Localizer.Get("LogTimeFrom"), now.AddDays(-1), () => applySelection()));
        content.Children.Add(CreateTimeInput(through, Localizer.Get("LogTimeThrough"), now, () => applySelection()));
        content.Children.Add(Hint("LogTimeRangeHint"));
        var error = ErrorText("LogTimeRangeInvalid"); content.Children.Add(error);
        applySelection = ShowLiveEditor(LogTimeButton, content, [from, through], () =>
        {
            var valid = LogTimeRange.TryParse(from.Text, through.Text, TimeZoneInfo.Local, out var range);
            error.Visibility = valid ? Visibility.Collapsed : Visibility.Visible;
            if (!valid) return false;
            var changed = timeRange != range;
            timeRange = range;
            timeFromText = from.Text.Trim(); timeThroughText = through.Text.Trim();
            if (!changed) UpdateFilterChips();
            return changed;
        });
    }

    private void LogMessageButton_Click(object sender, RoutedEventArgs e)
    {
        DismissFilterEditor(commitPending: true);
        var menu = new MenuFlyout();
        foreach (var category in Categories)
        {
            var item = new ToggleMenuFlyoutItem { Text = CategoryLabel(category), IsChecked = category == componentCategory };
            item.Click += async (_, _) => { componentCategory = category; await FiltersChangedAsync(); };
            menu.Items.Add(item);
        }
        Present(menu, LogMessageButton);
    }

    private static TextBlock Hint(string key) => new()
    {
        Text = Localizer.Get(key), FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap,
    };
    private static TextBlock ErrorText(string key)
    {
        var error = new TextBlock { Text = Localizer.Get(key), TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, FontSize = 12 };
        AutomationProperties.SetLiveSetting(error, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Assertive);
        return error;
    }

    private Action ShowLiveEditor(Button anchor, StackPanel content, TextBox[] inputs, Func<bool> apply)
    {
        var flyout = new Flyout { Content = content };
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(250);
        timer.IsRepeating = false;
        var dirty = false;
        var stopped = false;
        var lastText = inputs.Select(input => input.Text).ToArray();
        void Commit()
        {
            timer.Stop();
            var text = inputs.Select(input => input.Text).ToArray();
            if (stopped || !dirty && text.SequenceEqual(lastText)) return;
            dirty = false;
            lastText = text;
            if (apply()) _ = FiltersChangedAsync();
        }
        void Changed(object sender, TextChangedEventArgs args)
        {
            if (stopped) return;
            var text = inputs.Select(input => input.Text).ToArray();
            // Initial Text notifications are not an edit; opening must not start a query.
            if (text.SequenceEqual(lastText)) return;
            lastText = text;
            dirty = true;
            timer.Stop();
            timer.Start();
        }
        void ApplyNow()
        {
            if (stopped) return;
            dirty = true;
            Commit();
        }
        Action<bool>? stop = null;
        stop = commitPending =>
        {
            if (stopped) return;
            if (commitPending) Commit();
            stopped = true;
            timer.Stop();
            foreach (var input in inputs) input.TextChanged -= Changed;
            if (stopFilterEdit == stop) stopFilterEdit = null;
        };
        foreach (var input in inputs) input.TextChanged += Changed;
        timer.Tick += (_, _) => Commit();
        content.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, args) =>
        {
            if (args.Key != Windows.System.VirtualKey.Enter || args.OriginalSource is not TextBox) return;
            args.Handled = true;
            ApplyNow();
        }), true);
        flyout.Opened += (_, _) => { inputs[0].Focus(FocusState.Programmatic); inputs[0].SelectAll(); };
        // Finish the last valid edit on dismissal; a chip clear cancels pending work first.
        flyout.Closing += (_, _) => stop(IsLoaded);
        Present(flyout, anchor);
        stopFilterEdit = stop;
        return ApplyNow;
    }

    private void DismissFilterEditor(bool commitPending)
    {
        stopFilterEdit?.Invoke(commitPending);
        stopFilterEdit = null;
        filterFlyout?.Hide();
    }

    private void Present(FlyoutBase flyout, Button anchor)
    {
        DismissFilterEditor(commitPending: true);
        filterFlyout = flyout;
        flyout.Closed += (_, _) =>
        {
            if (!ReferenceEquals(filterFlyout, flyout)) return;
            filterFlyout = null;
            if (IsLoaded) anchor.Focus(FocusState.Programmatic);
        };
        flyout.ShowAt(anchor);
    }
}
