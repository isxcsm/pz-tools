using System.Runtime.InteropServices;
using System.Text;

namespace PzTools.GameBridge;

/// <summary>
/// Why the attach helper could not reach the game, for the log and, where the cause is a known one, for a precise word
/// to the player. The helper's first line on failure names the step it stopped at (see AttachMain); the rest is what
/// commonly makes an attach fail on a player's machine: a launch option that turns attaching off, a folder named
/// outside ASCII, the rights each side runs with (the app always as administrator, by its manifest, so a game with
/// more rights than it is not a cause). The diagnostics leave out full paths, which hold the user's name, and keep only
/// whether each held other letters.
/// </summary>
public static partial class AttachDiagnostics
{
    /// <summary>The helper's mark (AttachMain.FAILURE_MARK).</summary>
    public const string FailureMark = "PZTOOLS-ATTACH-FAILED";
    /// <summary>The helper's line saying where each file it handed the game came from (AttachMain.handed).</summary>
    public const string HandedMark = "PZTOOLS-ATTACH-HANDED";

    /// <summary>The game was started with attaching turned off (-XX:+DisableAttachMechanism).</summary>
    public const string DisabledCode = "attach-disabled";

    /// <summary>The failure as an exception: its code a known cause where there is one, its detail for the log.</summary>
    public static GameSaveException Failure(int processId, string helperOutput, int? exitCode, string bridgeDirectory)
    {
        var (stage, error) = Read(helperOutput);
        var rights = Rights(processId);
        var code = Classify(error);
        var message = Scrub(stage is null ? FirstLine(helperOutput) : $"{stage}: {error}");
        return new GameSaveException(code, message.Length > 0 ? message : "The attach helper failed without a message.",
            Describe(stage, error, exitCode, rights, bridgeDirectory, helperOutput));
    }

    /// <summary>The same detail, for a helper failure reported under another code (the runtime and extension links).</summary>
    public static string Describe(int processId, string helperOutput, int? exitCode, string bridgeDirectory)
    {
        var (stage, error) = Read(helperOutput);
        return Describe(stage, error, exitCode, Rights(processId), bridgeDirectory, helperOutput);
    }

    /// <summary>The step and the error from the helper's mark; none when it printed none (an older helper, a crash).</summary>
    public static (string? Stage, string? Error) Read(string helperOutput)
    {
        foreach (var line in helperOutput.Split('\n'))
        {
            if (!line.StartsWith(FailureMark + "\t", StringComparison.Ordinal)) continue;
            var fields = line.TrimEnd('\r').Split('\t', 3);
            return (fields.Length > 1 ? fields[1] : null, fields.Length > 2 ? fields[2] : null);
        }
        return (null, null);
    }

    /// <summary>A known cause, or the general attach failure.</summary>
    public static string Classify(string? error) =>
        error?.Contains("does not support the attach mechanism", StringComparison.OrdinalIgnoreCase) == true ? DisabledCode : "attach-failed";

    private static string Describe(string? stage, string? error, int? exitCode, ProcessRights rights, string bridgeDirectory,
        string helperOutput)
    {
        static string YesNo(bool? value) => value switch { true => "yes", false => "no", _ => "unknown" };
        var text = new StringBuilder();
        text.Append("stage=").Append(stage ?? "unknown");
        text.Append("; error=").Append(error ?? FirstLine(helperOutput));
        text.Append("; exit=").Append(exitCode?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "none");
        text.Append("; appElevated=").Append(YesNo(rights.AppElevated));
        text.Append("; gameElevated=").Append(YesNo(rights.GameElevated));
        if (rights.GameRightsKnown != true) text.Append(" (game rights unreadable: ").Append(rights.Note ?? "unknown").Append(')');
        text.Append("; gameJava=").Append(rights.GameImage ?? "unknown");
        // Which files reached the game from their own path and which as a copy in a folder of plain letters.
        foreach (var line in helperOutput.Split('\n'))
            if (line.StartsWith(HandedMark + "\t", StringComparison.Ordinal))
                text.Append("; handed=").Append(line[(HandedMark.Length + 1)..].TrimEnd('\r'));
        text.Append("; appFolderNonAscii=").Append(YesNo(NonAscii(bridgeDirectory)));
        text.Append("; tempNonAscii=").Append(YesNo(NonAscii(Path.GetTempPath())));
        text.Append("; profileNonAscii=").Append(YesNo(NonAscii(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile))));
        text.Append("; os=").Append(Environment.OSVersion.VersionString);
        // The helper's own words last, its tail if long: the stack trace says where inside the JVM it stopped.
        var output = helperOutput.Trim();
        if (output.Length > 0) text.Append("; helper=").Append(output.Length <= 3000 ? output : "…" + output[^3000..]);
        return Scrub(text.ToString());
    }

    /// <summary>
    /// The text with its paths cut to what says something without naming anyone: a Java exception names the file it
    /// failed on, under the user's own folder. The user's own and temporary folders by name; any other path by its last
    /// part.
    /// </summary>
    internal static string Scrub(string text)
    {
        foreach (var (folder, name) in new[]
        {
            (Path.GetTempPath(), "%TEMP%\\"),
            (Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "%LOCALAPPDATA%"),
            (Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "%USERPROFILE%"),
        })
            if (folder.Length > 3) text = text.Replace(folder, name, StringComparison.OrdinalIgnoreCase);
        return AbsolutePath().Replace(text, path => "…\\" + Path.GetFileName(path.Value.TrimEnd('\\', '/')));
    }

    // A drive or network path: folders, which may hold spaces ("Program Files"), then a last part up to a space, so
    // the words after a path ("(Access is denied)") stay.
    [System.Text.RegularExpressions.GeneratedRegex(@"(?<![\w%])(?:[A-Za-z]:|\\\\[^\\\s]+)[\\/](?:[^\\/\r\n""'<>|;:*?]*[\\/])*[^\\/\s""'<>|;:*?]*")]
    private static partial System.Text.RegularExpressions.Regex AbsolutePath();

    private static string FirstLine(string text)
    {
        foreach (var line in text.Split('\n'))
            if (line.Trim() is { Length: > 0 } first) return first;
        return "";
    }

    private static bool? NonAscii(string? path) => string.IsNullOrEmpty(path) ? null : path.Any(character => character > 0x7E);

    /// <summary>The app's rights and, as far as Windows tells, the game's; and the game's executable by name.</summary>
    public sealed record ProcessRights(bool? AppElevated, bool? GameElevated, bool? GameRightsKnown, string? GameImage, string? Note);

    /// <summary>
    /// Whether the app and the game run elevated. A process without rights cannot read an elevated process's token:
    /// the game's rights are then unknown, and that refusal is itself the usual sign of a game run as administrator or
    /// as another user.
    /// </summary>
    public static ProcessRights Rights(int processId)
    {
        if (!OperatingSystem.IsWindows()) return new(null, null, null, null, "not Windows");
        var app = Elevated(Native.GetCurrentProcess(), out _);
        // Unreadable counts as a matter of rights only when Windows says access is denied; a game that has exited
        // since is not.
        const int accessDenied = 5;
        var process = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero)
        {
            var opening = Marshal.GetLastWin32Error();
            return new(app, null, opening == accessDenied ? false : null, null, $"open process: error {opening}");
        }
        try
        {
            var image = ImageName(process);
            var game = Elevated(process, out var error);
            return new(app, game, game is not null ? true : error == accessDenied ? false : null, image,
                game is null ? $"open token: error {error}" : null);
        }
        finally { Native.CloseHandle(process); }
    }

    /// <summary>The variable that names, for the attach helper, the account the game runs as (AttachMain.principals).</summary>
    public const string GameAccountVariable = "PZTOOLS_GAME_ACCOUNT";

    /// <summary>
    /// Names for the attach helper the account the game runs as, which must be able to read what it is handed: the app
    /// runs as administrator, possibly as another account than the player's (an administrator's password typed for a
    /// standard user), while the game runs as the player. Left unsaid when Windows does not tell; the helper then
    /// takes the account the app was started for.
    /// </summary>
    public static void PassGameAccount(System.Diagnostics.ProcessStartInfo start, int processId)
    {
        if (AccountOf(processId) is { } account) start.Environment[GameAccountVariable] = account;
    }

    /// <summary>The account a process runs as, "DOMAIN\name"; none when Windows does not say.</summary>
    public static string? AccountOf(int processId)
    {
        if (!OperatingSystem.IsWindows()) return null;
        var process = Native.OpenProcess(Native.ProcessQueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero) return null;
        try
        {
            if (!Native.OpenProcessToken(process, Native.TokenQuery, out var token)) return null;
            try
            {
                Native.GetTokenInformation(token, Native.TokenUser, IntPtr.Zero, 0, out var size);
                if (size <= 0) return null;
                var buffer = Marshal.AllocHGlobal(size);
                try
                {
                    if (!Native.GetTokenInformation(token, Native.TokenUser, buffer, size, out _)) return null;
                    // TOKEN_USER begins with the SID's address.
                    var sid = new System.Security.Principal.SecurityIdentifier(Marshal.ReadIntPtr(buffer));
                    return sid.Translate(typeof(System.Security.Principal.NTAccount)).Value;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            // An account Windows cannot name (removed meanwhile), or a SID it cannot read.
            catch (SystemException) { return null; }
            finally { Native.CloseHandle(token); }
        }
        finally { Native.CloseHandle(process); }
    }

    private static bool? Elevated(IntPtr process, out int error)
    {
        error = 0;
        if (!Native.OpenProcessToken(process, Native.TokenQuery, out var token)) { error = Marshal.GetLastWin32Error(); return null; }
        try
        {
            var size = Marshal.SizeOf<int>();
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!Native.GetTokenInformation(token, Native.TokenElevation, buffer, size, out _)) { error = Marshal.GetLastWin32Error(); return null; }
                return Marshal.ReadInt32(buffer) != 0;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { Native.CloseHandle(token); }
    }

    // The game's executable by file name only: which Java runs it (the game's own, or another a launcher chose).
    private static string? ImageName(IntPtr process)
    {
        var capacity = 1024;
        var buffer = new StringBuilder(capacity);
        return Native.QueryFullProcessImageName(process, 0, buffer, ref capacity) ? Path.GetFileName(buffer.ToString()) : null;
    }

    private static class Native
    {
        public const uint ProcessQueryLimitedInformation = 0x1000;
        public const uint TokenQuery = 0x0008;
        public const int TokenElevation = 20;
        public const int TokenUser = 1;

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint access, bool inherit, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetTokenInformation(IntPtr token, int informationClass, IntPtr information, int length, out int returned);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
    }
}
