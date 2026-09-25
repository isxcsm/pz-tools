namespace PzTools.Backup.Core;

/// <summary>
/// A compact, non-authenticating change-detection fingerprint: the first 128 bits
/// of SHA-256. Pack checksums, copy verification and deduplication keep full hashes.
/// </summary>
public static class ContentFingerprint
{
    public const string Algorithm = "Sha256_128";
    public const string LegacyAlgorithm = "Sha256";
    public const int ByteLength = 16;
    public const int Sha256ByteLength = 32;

    public static byte[] FromSha256(ReadOnlySpan<byte> sha256)
    {
        if (sha256.Length != Sha256ByteLength)
            throw new ArgumentException("A complete SHA-256 digest is required.", nameof(sha256));
        return sha256[..ByteLength].ToArray();
    }

    public static string AlgorithmForLength(int length) => length switch
    {
        ByteLength => Algorithm,
        Sha256ByteLength => LegacyAlgorithm,
        _ => throw new ArgumentException("Unsupported content fingerprint length.", nameof(length)),
    };

    // The caller must first validate the stored algorithm. The full-scan query
    // supplies only known algorithm/length pairs (or a full SHA-256 checksum).
    public static bool MatchesSha256(ReadOnlySpan<byte> sha256, ReadOnlySpan<byte> expected) =>
        sha256.Length == Sha256ByteLength
        && expected.Length is ByteLength or Sha256ByteLength
        && sha256[..expected.Length].SequenceEqual(expected);
}
