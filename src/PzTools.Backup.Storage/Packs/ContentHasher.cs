using System.IO.Hashing;
using System.Security.Cryptography;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Packs;

internal interface IContentHasher : IDisposable
{
    void Append(ReadOnlySpan<byte> data);

    byte[] Finish();
}

internal static class ContentHasher
{
    public static IContentHasher Create(ChecksumAlgorithm algorithm) => algorithm switch
    {
        ChecksumAlgorithm.None => new NullContentHasher(),
        ChecksumAlgorithm.XxHash64 => new XxHash64ContentHasher(),
        ChecksumAlgorithm.Sha256 => new Sha256ContentHasher(),
        _ => throw new ArgumentException(
            $"Checksum algorithm {algorithm} must be resolved before use.",
            nameof(algorithm)),
    };

    private sealed class NullContentHasher : IContentHasher
    {
        public void Append(ReadOnlySpan<byte> data)
        {
        }

        public byte[] Finish() => [];

        public void Dispose()
        {
        }
    }

    private sealed class XxHash64ContentHasher : IContentHasher
    {
        private readonly XxHash64 hash = new();

        public void Append(ReadOnlySpan<byte> data) => hash.Append(data);

        public byte[] Finish() => hash.GetCurrentHash();

        public void Dispose()
        {
        }
    }

    private sealed class Sha256ContentHasher : IContentHasher
    {
        private readonly IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);

        public void Append(ReadOnlySpan<byte> data) => hash.AppendData(data);

        public byte[] Finish() => hash.GetHashAndReset();

        public void Dispose() => hash.Dispose();
    }
}
