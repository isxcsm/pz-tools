namespace PzTools.Process.Contracts;

/// <summary>Bounded technical detail, recorded separately from the short user-facing failure message.</summary>
public interface IFailureDiagnostics
{
    string? Diagnostics { get; }
}
