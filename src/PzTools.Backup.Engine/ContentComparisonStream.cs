using System.Buffers;

namespace PzTools.Backup.Engine;

// Owns only its scratch buffer; the caller owns the staged source stream.
// A fixed-size buffer also bounds memory when a writer supplies a very large block.
internal sealed class ContentComparisonStream : Stream
{
    private readonly Stream source;
    private readonly ArrayPool<byte> pool;
    private byte[]? scratch;

    internal ContentComparisonStream(Stream source, ArrayPool<byte>? pool = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (!source.CanRead) throw new ArgumentException("A readable source is required.", nameof(source));
        this.source = source;
        this.pool = pool ?? ArrayPool<byte>.Shared;
        scratch = this.pool.Rent(128 * 1024);
    }

    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => scratch is not null;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    private byte[] Buffer => scratch ?? throw new ObjectDisposedException(nameof(ContentComparisonStream));

    public async Task<bool> IsSourceExhaustedAsync(CancellationToken cancellationToken) =>
        await source.ReadAsync(Buffer.AsMemory(0, 1), cancellationToken) == 0;

    public override async ValueTask WriteAsync(
        ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        var actual = Buffer;
        cancellationToken.ThrowIfCancellationRequested();
        while (!buffer.IsEmpty)
        {
            var length = Math.Min(actual.Length, buffer.Length);
            try { await source.ReadExactlyAsync(actual.AsMemory(0, length), cancellationToken); }
            catch (EndOfStreamException) { throw new ContentMismatchException(); }
            if (!buffer.Span[..length].SequenceEqual(actual.AsSpan(0, length)))
                throw new ContentMismatchException();
            buffer = buffer[length..];
        }
    }

    public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));

    public override void Write(ReadOnlySpan<byte> buffer)
    {
        var actual = Buffer;
        while (!buffer.IsEmpty)
        {
            var length = Math.Min(actual.Length, buffer.Length);
            try { source.ReadExactly(actual.AsSpan(0, length)); }
            catch (EndOfStreamException) { throw new ContentMismatchException(); }
            if (!buffer[..length].SequenceEqual(actual.AsSpan(0, length)))
                throw new ContentMismatchException();
            buffer = buffer[length..];
        }
    }

    protected override void Dispose(bool disposing)
    {
        var returned = Interlocked.Exchange(ref scratch, null);
        if (returned is not null) pool.Return(returned, clearArray: true);
        base.Dispose(disposing);
    }

    public override void Flush() { }
    public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    internal sealed class ContentMismatchException : Exception;
}
