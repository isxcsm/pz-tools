using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PzTools.Projections;

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
    private static readonly string[] Categories = ["All", "Backup", "Restore", "Recovery", "Archive", "State", "Schedule", "Maintenance", "Other"];

    private static string CategoryLabel(string category) => Localizer.Get(category switch
    {
        "All" => "All",
        "Recovery" => "LogActivity.CharacterRecovery",
        _ => $"LogComponent.{category}",
    });

    private void LocalizeFilterHeaders()
    {
        filterFlyout?.Hide();
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
        // Filters are applied at the storage query, before grouping/counting/paging.
        // Input boxes are drafts until Apply/Enter: no per-keystroke I/O.
        pageIndex = 0;
        pageSnapshot = 0;
        await LoadPageAsync(resetSnapshot: true);
    }

    private void CloseFiltersAndQueries()
    {
        filterFlyout?.Hide();
        filterFlyout = null;
        ++queryVersion;
        pageQueryCancellation?.Cancel();
    }

    private void UpdateFilterChips()
    {
        var level = Localizer.Format("LogLevelAtOrAboveFormat", Localizer.Get($"LogLevel.{minimumLevel}"));
        var hint = Localizer.Format("LogLevelCycleHint", level);
        AppToolTip.SetTip(LogLevelButton, hint);
        AutomationProperties.SetName(LogLevelButton, hint);
        FilterChips.Children.Clear();
        AddChip(logRange is not null, LogNumberHeader.Text, logRange?.ToString() ?? "", () => logRange = null);
        AddChip(minimumLevel > recordMinimum, LogLevelHeader.Text, level,
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
        var levels = Enum.GetValues<LogLevel>().Where(level => level >= recordMinimum).ToArray();
        minimumLevel = levels[(Array.IndexOf(levels, minimumLevel) + 1) % levels.Length];
        levelChosenByUser = true;
        await FiltersChangedAsync();
    }

    private void ShowNumberFilter(Button anchor, bool operation)
    {
        var input = new TextBox
        {
            Header = Localizer.Get(operation ? "LogRunIndexFilter" : "LogNumberHeader"),
            Text = (operation ? runRange : logRange)?.ToString() ?? "", PlaceholderText = "42 / 40-50",
        };
        var content = new StackPanel { Width = 280, Spacing = 10 };
        content.Children.Add(input);
        content.Children.Add(Hint("LogNumberRangeHint"));
        var error = ErrorText("LogNumberRangeInvalid"); content.Children.Add(error);
        ShowEditor(anchor, content, input, () =>
        {
            if (!LogNumberRange.TryParse(input.Text, out var range)) { error.Visibility = Visibility.Visible; return false; }
            if (operation) runRange = range; else logRange = range;
            return true;
        }, () => { if (operation) runRange = null; else logRange = null; });
    }

    private void LogTimeButton_Click(object sender, RoutedEventArgs e)
    {
        var placeholder = DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        var from = new TextBox { Header = Localizer.Get("LogTimeFrom"), Text = timeFromText, PlaceholderText = placeholder };
        var through = new TextBox { Header = Localizer.Get("LogTimeThrough"), Text = timeThroughText, PlaceholderText = placeholder };
        var content = new StackPanel { Width = 320, Spacing = 10 };
        content.Children.Add(new TextBlock { Text = Localizer.Format("LogLocalTimeHint", LogTimeFormatter.ZoneLabel(DateTimeOffset.Now)), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(from); content.Children.Add(through); content.Children.Add(Hint("LogTimeRangeHint"));
        var error = ErrorText("LogTimeRangeInvalid"); content.Children.Add(error);
        ShowEditor(LogTimeButton, content, from, () =>
        {
            if (!LogTimeRange.TryParse(from.Text, through.Text, TimeZoneInfo.Local, out var range))
            { error.Visibility = Visibility.Visible; return false; }
            timeRange = range;
            timeFromText = from.Text.Trim(); timeThroughText = through.Text.Trim();
            return true;
        }, ClearTime);
    }

    private void LogMessageButton_Click(object sender, RoutedEventArgs e)
    {
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

    private void ShowEditor(Button anchor, StackPanel content, TextBox input, Func<bool> apply, Action clear)
    {
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var clearButton = new Button { Content = Localizer.Get("LogFilterClear") };
        var applyButton = new Button { Content = Localizer.Get("LogFilterApply") };
        actions.Children.Add(clearButton); actions.Children.Add(applyButton); content.Children.Add(actions);
        var flyout = new Flyout { Content = content };
        var committing = false;
        async Task CommitAsync(bool reset)
        {
            if (committing) return;
            if (reset) clear(); else if (!apply()) { input.Focus(FocusState.Programmatic); return; }
            committing = true;
            flyout.Hide();
            await FiltersChangedAsync();
        }
        clearButton.Click += async (_, _) => await CommitAsync(true);
        applyButton.Click += async (_, _) => await CommitAsync(false);
        content.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(async (_, args) =>
        {
            if (args.Key != Windows.System.VirtualKey.Enter) return;
            args.Handled = true;
            await CommitAsync(false);
        }), true);
        flyout.Opened += (_, _) => { input.Focus(FocusState.Programmatic); input.SelectAll(); };
        Present(flyout, anchor);
    }

    private void Present(FlyoutBase flyout, Button anchor)
    {
        filterFlyout?.Hide();
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
