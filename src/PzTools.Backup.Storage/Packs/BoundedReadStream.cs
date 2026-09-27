namespace PzTools.Backup.Storage.Packs;

internal sealed class BoundedReadStream : Stream
{
    private readonly Stream inner;
    private long remaining;

    public BoundedReadStream(Stream inner, long length)
    {
        this.inner = inner;
        remaining = length;
    }

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        var requested = (int)Math.Min(count, remaining);
        if (requested == 0)
        {
            return 0;
        }

        var read = inner.Read(buffer, offset, requested);
        remaining -= read;
        return read;
    }

    public override async ValueTask<int> ReadAsync(
        Memory<byte> buffer,
        CancellationToken cancellationToken = default)
    {
        var requested = (int)Math.Min(buffer.Length, remaining);
        if (requested == 0)
        {
            return 0;
        }

        var read = await inner.ReadAsync(buffer[..requested], cancellationToken);
        remaining -= read;
        return read;
    }

    public override void Flush() => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) =>
        throw new NotSupportedException();
}
