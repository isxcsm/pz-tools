using System.Globalization;

namespace PzTools.Process.Contracts;

[Flags]
public enum HotKeyModifiers { None = 0, Alt = 1, Control = 2, Shift = 4, Windows = 8 }

/// <summary>
/// A key combination the app takes from Windows while it runs, written as "Ctrl+Shift+F9". The key is a Windows
/// virtual-key code. A letter, digit or other typing key needs Ctrl or Alt, or it would be taken from every program's
/// typing; function keys and a few rarely typed ones may stand alone.
/// </summary>
public readonly record struct HotKeyGesture(HotKeyModifiers Modifiers, int Key)
{
    private static readonly (HotKeyModifiers Modifier, string Name)[] ModifierNames =
        [(HotKeyModifiers.Control, "Ctrl"), (HotKeyModifiers.Alt, "Alt"), (HotKeyModifiers.Shift, "Shift"), (HotKeyModifiers.Windows, "Win")];

    private static readonly Dictionary<int, string> Names = BuildNames();
    private static readonly Dictionary<string, int> Codes = Names.ToDictionary(item => item.Value, item => item.Key, StringComparer.OrdinalIgnoreCase);

    private static Dictionary<int, string> BuildNames()
    {
        var names = new Dictionary<int, string>();
        for (var letter = 'A'; letter <= 'Z'; letter++) names[letter] = letter.ToString();
        for (var digit = '0'; digit <= '9'; digit++) names[digit] = digit.ToString();
        for (var index = 1; index <= 24; index++) names[0x6F + index] = "F" + index.ToString(CultureInfo.InvariantCulture);
        for (var index = 0; index <= 9; index++) names[0x60 + index] = "Num" + index.ToString(CultureInfo.InvariantCulture);
        foreach (var (code, name) in new[]
                 {
                     (0x2D, "Insert"), (0x2E, "Delete"), (0x24, "Home"), (0x23, "End"), (0x21, "PageUp"), (0x22, "PageDown"),
                     (0x13, "Pause"), (0x91, "ScrollLock"), (0x25, "Left"), (0x26, "Up"), (0x27, "Right"), (0x28, "Down"),
                     (0x6A, "Num*"), (0x6B, "Num+"), (0x6D, "Num-"), (0x6E, "Num."), (0x6F, "Num/"),
                 })
            names[code] = name;
        return names;
    }

    /// <summary>Keys that may be taken alone: nobody types with them.</summary>
    private bool StandsAlone => Key is >= 0x70 and <= 0x87 || Key is 0x13 or 0x91;

    /// <summary>Whether this is a combination the app may take: a known key, and Ctrl, Alt or Win with a typing key.</summary>
    public bool IsValid =>
        Names.ContainsKey(Key) && (StandsAlone || (Modifiers & (HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Windows)) != 0);

    public static bool IsKnownKey(int key) => Names.ContainsKey(key);

    public override string ToString()
    {
        var modifiers = Modifiers;
        return string.Join("+", ModifierNames.Where(item => modifiers.HasFlag(item.Modifier)).Select(item => item.Name)
            .Append(Names.TryGetValue(Key, out var name) ? name : "?"));
    }

    /// <summary>Reads "Ctrl+Shift+F9"; null for text that is no valid combination (an empty one included).</summary>
    public static HotKeyGesture? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var parts = text.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        // "Num+" ends in the separator itself.
        if (text.TrimEnd().EndsWith("Num+", StringComparison.OrdinalIgnoreCase)) parts = [.. parts[..^1], "Num+"];
        if (parts.Length == 0) return null;
        var modifiers = HotKeyModifiers.None;
        foreach (var part in parts[..^1])
        {
            var modifier = ModifierNames.FirstOrDefault(item => item.Name.Equals(part, StringComparison.OrdinalIgnoreCase)
                || part.Equals("Control", StringComparison.OrdinalIgnoreCase) && item.Modifier == HotKeyModifiers.Control);
            if (modifier.Name is null || modifiers.HasFlag(modifier.Modifier)) return null;
            modifiers |= modifier.Modifier;
        }
        if (!Codes.TryGetValue(parts[^1], out var key)) return null;
        var gesture = new HotKeyGesture(modifiers, key);
        return gesture.IsValid ? gesture : null;
    }
}

/// <summary>What each hotkey does; the settings keep one combination, or none, for each.</summary>
public enum HotKeyAction { SaveLast, Record, RecordMode, RollingToggle, ManualBackup, BackupToggle, Status }

/// <summary>
/// The combinations the user gave the app's actions, as written ("Ctrl+Shift+F9"), empty for none. Only saving the
/// last minutes has one at first: every combination is taken from all other programs while the app runs.
/// </summary>
public sealed record HotKeySettings(
    string SaveLast = "Ctrl+Shift+F9",
    string Record = "",
    string RecordMode = "",
    string RollingToggle = "",
    string ManualBackup = "",
    string BackupToggle = "",
    string Status = "")
{
    public string Get(HotKeyAction action) => action switch
    {
        HotKeyAction.SaveLast => SaveLast,
        HotKeyAction.Record => Record,
        HotKeyAction.RecordMode => RecordMode,
        HotKeyAction.RollingToggle => RollingToggle,
        HotKeyAction.ManualBackup => ManualBackup,
        HotKeyAction.BackupToggle => BackupToggle,
        _ => Status,
    };

    public HotKeySettings With(HotKeyAction action, string value) => action switch
    {
        HotKeyAction.SaveLast => this with { SaveLast = value },
        HotKeyAction.Record => this with { Record = value },
        HotKeyAction.RecordMode => this with { RecordMode = value },
        HotKeyAction.RollingToggle => this with { RollingToggle = value },
        HotKeyAction.ManualBackup => this with { ManualBackup = value },
        HotKeyAction.BackupToggle => this with { BackupToggle = value },
        _ => this with { Status = value },
    };

    /// <summary>Each action's combination, parsed; those without one (or with text that is none) are left out.</summary>
    public IReadOnlyDictionary<HotKeyAction, HotKeyGesture> Gestures() =>
        Enum.GetValues<HotKeyAction>().Select(action => (action, Gesture: HotKeyGesture.Parse(Get(action))))
            .Where(item => item.Gesture is not null).ToDictionary(item => item.action, item => item.Gesture!.Value);

    /// <summary>Written back in one form ("ctrl+shift+f9" as "Ctrl+Shift+F9"); text that is no combination becomes none.</summary>
    public HotKeySettings Normalized() =>
        Enum.GetValues<HotKeyAction>().Aggregate(this, (settings, action) =>
            settings.With(action, HotKeyGesture.Parse(settings.Get(action))?.ToString() ?? ""));

    /// <summary>A combination given to two actions: the second would never fire.</summary>
    public bool HasDuplicates() => Gestures().Values.GroupBy(gesture => gesture).Any(group => group.Count() > 1);
}
