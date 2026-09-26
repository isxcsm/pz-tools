using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;

namespace PzTools.App;

public sealed partial class LogsPage
{
    private static FrameworkElement CreateTimeInput(TextBox input, string label, DateTimeOffset fallback, Action selectionChanged)
    {
        // Selecting a value updates the input; merely opening the picker does not apply a filter.
        var group = new StackPanel { Spacing = 6 };
        group.Children.Add(new TextBlock { Text = label });
        AutomationProperties.SetName(input, label);
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var choose = new Button { Content = new FontIcon { Glyph = "\uE787", FontSize = 16 }, Padding = new Thickness(10, 8, 10, 8) };
        var pickerLabel = $"{label} · {Localizer.Get("LogChooseDateTime")}";
        AppToolTip.SetTip(choose, pickerLabel);
        AutomationProperties.SetName(choose, pickerLabel);
        Grid.SetColumn(choose, 1); row.Children.Add(input); row.Children.Add(choose); group.Children.Add(row);
        var date = new CalendarDatePicker
        {
            Header = Localizer.Get("LogDateLabel"), Language = Localizer.Culture.Name,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MinDate = new DateTimeOffset(1601, 1, 1, 12, 0, 0, TimeSpan.Zero),
            MaxDate = new DateTimeOffset(9998, 12, 31, 12, 0, 0, TimeSpan.Zero),
        };
        var time = new TimePicker { Header = Localizer.Get("Time"), ClockIdentifier = "24HourClock",
            Language = Localizer.Culture.Name, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(date, $"{label} · {Localizer.Get("LogDateLabel")}");
        AutomationProperties.SetName(time, $"{label} · {Localizer.Get("Time")}");
        var picker = new StackPanel { Width = 280, Spacing = 12, Language = Localizer.Culture.Name };
        picker.Children.Add(date); picker.Children.Add(time);
        var flyout = new Flyout { Content = picker };
        choose.Flyout = flyout;
        var initializing = true;
        DateTime? lastDate = null;
        TimeSpan? lastTime = null;
        flyout.Opening += (_, _) =>
        {
            initializing = true;
            var value = LogTimeFilterDraft.PickerValue(input.Text, fallback, TimeZoneInfo.Local);
            var day = DateTime.SpecifyKind(value.Date.AddHours(12), DateTimeKind.Unspecified);
            date.Date = new DateTimeOffset(day, TimeZoneInfo.Local.GetUtcOffset(day));
            time.SelectedTime = value.TimeOfDay;
            lastDate = date.Date?.Date;
            lastTime = time.SelectedTime;
            initializing = false;
        };
        void SelectionChanged()
        {
            if (initializing || date.Date is not { } day || time.SelectedTime is not { } selected) return;
            if (lastDate == day.Date && lastTime == selected) return;
            lastDate = day.Date; lastTime = selected;
            input.Text = LogTimeFilterDraft.FormatSelection(day.LocalDateTime, selected);
            selectionChanged();
        }
        flyout.Closed += (_, _) => initializing = true;
        date.DateChanged += (_, _) => SelectionChanged();
        time.SelectedTimeChanged += (_, _) => SelectionChanged();
        return group;
    }
}
