using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Repository;

internal static class StorageAlgorithmCodec
{
    public static int Checksum(string value) => value switch
    {
        "None" => (int)ChecksumAlgorithm.None,
        "XxHash64" => (int)ChecksumAlgorithm.XxHash64,
        "Sha256" => (int)ChecksumAlgorithm.Sha256,
        _ => throw new InvalidDataException($"Unsupported stored checksum '{value}'."),
    };

    public static int Compression(string value) => value switch
    {
        "None" => (int)CompressionAlgorithm.None,
        "Brotli" => (int)CompressionAlgorithm.Brotli,
        _ => throw new InvalidDataException($"Unsupported stored compression '{value}'."),
    };

    public static string Checksum(int value) => value switch
    {
        (int)ChecksumAlgorithm.None => "None",
        (int)ChecksumAlgorithm.XxHash64 => "XxHash64",
        (int)ChecksumAlgorithm.Sha256 => "Sha256",
        _ => throw new InvalidDataException($"Unsupported stored checksum code '{value}'."),
    };

    public static string Compression(int value) => value switch
    {
        (int)CompressionAlgorithm.None => "None",
        (int)CompressionAlgorithm.Brotli => "Brotli",
        _ => throw new InvalidDataException($"Unsupported stored compression code '{value}'."),
    };
}
