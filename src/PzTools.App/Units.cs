namespace PzTools.App;

/// <summary>
/// Sizes and times as the UI language writes them: its number format and its own unit symbols, the ones Windows uses
/// in that language ("Ko" in French, "МБ" and "мс" in Russian), always after the number and a space.
/// </summary>
internal static class Units
{
    private static readonly string[] SizeKeys = ["Unit.Byte", "Unit.Kilobyte", "Unit.Megabyte", "Unit.Gigabyte", "Unit.Terabyte"];

    /// <summary>
    /// A size in the largest unit it reaches (by 1024), from <paramref name="smallest"/> up: 0 bytes, 1 kilobytes, and
    /// so on. <paramref name="format"/> is the number's.
    /// </summary>
    public static string Bytes(long bytes, string format = "0.#", int smallest = 0)
    {
        var value = bytes / Math.Pow(1024, smallest);
        var unit = smallest;
        while (Math.Abs(value) >= 1024 && unit < SizeKeys.Length - 1)
        {
            value /= 1024;
            unit++;
        }
        return With(value.ToString(format, Localizer.Culture), SizeKeys[unit]);
    }

    /// <summary>A number already written, followed by the millisecond's symbol.</summary>
    public static string Milliseconds(string number) => With(number, "Unit.Millisecond");

    /// <summary>A number already written, followed by the second's symbol.</summary>
    public static string Seconds(string number) => With(number, "Unit.Second");

    private static string With(string number, string unitKey) => number + " " + Localizer.Get(unitKey);
}
