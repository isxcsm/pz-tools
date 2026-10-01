namespace PzTools.Process.Contracts;

/// <summary>설치 파일, 앱 제어 데이터, 사용자 백업 저장소의 경계를 정의합니다.</summary>
public sealed record PzToolsPathLayout(
    string InstallRoot,
    string DataRoot,
    string WorkerRoot,
    string DefaultsRoot,
    string ControlDatabasePath,
    string StateDatabasePath,
    string SchedulerDatabasePath,
    string OperationsRoot,
    string CacheRoot,
    string TempRoot)
{
    public string ConfigurationRoot => Path.Combine(DataRoot, "config");

    public static PzToolsPathLayout CreateDefault(
        string? installRoot = null,
        string? dataRoot = null)
    {
        var install = Path.GetFullPath(installRoot ?? AppContext.BaseDirectory);
        var data = Path.GetFullPath(dataRoot ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PzTools"));
        return new PzToolsPathLayout(
            install,
            data,
            install,
            Path.Combine(install, "defaults"),
            Path.Combine(data, "control.db"),
            Path.Combine(data, "state.db"),
            Path.Combine(data, "scheduler.db"),
            Path.Combine(data, "operations"),
            Path.Combine(data, "cache"),
            Path.Combine(data, "temp"));
    }

    public string CreateOperationIdentity(string component, string operationId)
    {
        ValidateSegment(component, nameof(component));
        ValidateSegment(operationId, nameof(operationId));
        return Path.Combine(OperationsRoot, component, operationId);
    }

    private static void ValidateSegment(string value, string parameter)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value, parameter);
        if (value is "." or ".." || value.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw new ArgumentException("The value cannot be used as a path separator.", parameter);
    }
}
