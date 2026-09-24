using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Engine;

public static class StorageStrategyResolver
{
    public static ChecksumAlgorithm Resolve(ChecksumAlgorithm algorithm) => algorithm switch
    {
        ChecksumAlgorithm.Auto => ChecksumAlgorithm.XxHash64,
        _ => algorithm,
    };

    public static CompressionAlgorithm Resolve(CompressionAlgorithm algorithm) => algorithm switch
    {
        CompressionAlgorithm.Auto => CompressionAlgorithm.Brotli,
        _ => algorithm,
    };
}
