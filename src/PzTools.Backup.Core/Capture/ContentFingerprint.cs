namespace PzTools.Backup.Core.Capture;

/// <summary>Non-adversarial change detection only. Pack checksums remain independent.</summary>
public static class ContentFingerprint
{
    public const int Length = 16;
    public const string AlgorithmName = "Sha256Truncated128";

    public static byte[] FromSha256(ReadOnlySpan<byte> digest)
    {
        if (digest.Length != 32) throw new ArgumentException("Expected a full SHA-256 digest.", nameof(digest));
        return digest[..Length].ToArray();
    }

    public static bool MatchesSha256(ReadOnlySpan<byte> fingerprint, ReadOnlySpan<byte> digest)
    {
        if (fingerprint.Length != Length)
            throw new InvalidDataException("Expected a 128-bit content fingerprint.");
        if (digest.Length != 32) throw new ArgumentException("Expected a full SHA-256 digest.", nameof(digest));
        return fingerprint.SequenceEqual(digest[..Length]);
    }
}
