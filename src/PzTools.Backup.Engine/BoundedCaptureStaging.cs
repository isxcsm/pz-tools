namespace PzTools.Backup.Engine;

// A private pool, rather than ArrayPool.Shared, keeps retained staging capacity inside
// the same budget as copies being read, queued, or written to a pack.
internal sealed class BoundedStagingBufferPool
{
    private readonly int bufferSize;
    private readonly SemaphoreSlim slots;
    private readonly Stack<byte[]> available = [];
    private readonly object gate = new();
    private long allocatedBytes;
    private long leasedBytes;

    internal BoundedStagingBufferPool(int bufferSize, long maximumBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(bufferSize);
        if (maximumBytes < bufferSize)
            throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        this.bufferSize = bufferSize;
        var count = checked((int)(maximumBytes / bufferSize));
        slots = new SemaphoreSlim(count, count);
    }

    internal long AllocatedBytes { get { lock (gate) return allocatedBytes; } }
    internal long LeasedBytes { get { lock (gate) return leasedBytes; } }

    internal async ValueTask<Lease> RentAsync(CancellationToken cancellationToken)
    {
        await slots.WaitAsync(cancellationToken);
        try
        {
            lock (gate)
            {
                if (!available.TryPop(out var buffer))
                {
                    buffer = new byte[bufferSize];
                    allocatedBytes += buffer.Length;
                }
                leasedBytes += buffer.Length;
                return new Lease(this, buffer);
            }
        }
        catch
        {
            slots.Release();
            throw;
        }
    }

    private void Return(byte[] buffer)
    {
        lock (gate)
        {
            leasedBytes -= buffer.Length;
            available.Push(buffer);
        }
        slots.Release();
    }

    internal sealed class Lease(BoundedStagingBufferPool owner, byte[] buffer) : IDisposable
    {
        private BoundedStagingBufferPool? owner = owner;
        internal byte[] Buffer { get; } = buffer;
        public void Dispose() => Interlocked.Exchange(ref owner, null)?.Return(Buffer);
    }
}

// The memory stream cannot expand. Crossing the threshold copies its existing
// contents to a private temporary file before returning its entire buffer lease.
internal sealed class SpillableCaptureStream : Stream
{
    private readonly Func<FileStream> createDiskStaging;
    private BoundedStagingBufferPool.Lease? lease;
    private Stream content;
    private int disposed;

    internal SpillableCaptureStream(
        BoundedStagingBufferPool.Lease lease, Func<FileStream> createDiskStaging)
    {
        this.lease = lease;
        this.createDiskStaging = createDiskStaging;
        content = new MemoryStream(lease.Buffer, 0, lease.Buffer.Length, writable: true);
        content.SetLength(0);
    }

    internal bool IsSpilled => lease is null;
    private Stream Content
    {
        get
        {
            ObjectDisposedException.ThrowIf(disposed != 0, this);
            return content;
        }
    }

    public override bool CanRead => disposed == 0 && content.CanRead;
    public override bool CanSeek => disposed == 0 && content.CanSeek;
    public override bool CanWrite => disposed == 0 && content.CanWrite;
    public override long Length => Content.Length;
    public override long Position { get => Content.Position; set => Content.Position = value; }
    public override void Flush() => Content.Flush();
    public override Task FlushAsync(CancellationToken cancellationToken) => Content.FlushAsync(cancellationToken);
    public override long Seek(long offset, SeekOrigin origin) => Content.Seek(offset, origin);
    public override int Read(byte[] buffer, int offset, int count) => Content.Read(buffer, offset, count);
    public override int Read(Span<byte> buffer) => Content.Read(buffer);
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        Content.ReadAsync(buffer, offset, count, cancellationToken);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
        Content.ReadAsync(buffer, cancellationToken);

    public override void SetLength(long value)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(value);
        _ = Content;
        if (lease is not null && value > lease.Buffer.Length) Spill();
        content.SetLength(value);
    }

    public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));

    public override void Write(ReadOnlySpan<byte> buffer)
    {
        if (NeedsSpill(buffer.Length)) Spill();
        content.Write(buffer);
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        WriteAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override async ValueTask WriteAsync(
        ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (NeedsSpill(buffer.Length)) await SpillAsync(cancellationToken);
        await content.WriteAsync(buffer, cancellationToken);
    }

    private bool NeedsSpill(int count) =>
        checked(Content.Position + count) > (lease?.Buffer.Length ?? long.MaxValue);

    private void Spill()
    {
        var memory = content;
        var disk = createDiskStaging();
        try
        {
            disk.Write(lease!.Buffer.AsSpan(0, checked((int)memory.Length)));
            disk.Position = memory.Position;
        }
        catch
        {
            disk.Dispose();
            throw;
        }
        content = disk;
        memory.Dispose();
        lease.Dispose();
        lease = null;
    }

    private async Task SpillAsync(CancellationToken cancellationToken)
    {
        var memory = content;
        var disk = createDiskStaging();
        try
        {
            await disk.WriteAsync(lease!.Buffer.AsMemory(0, checked((int)memory.Length)), cancellationToken);
            disk.Position = memory.Position;
        }
        catch
        {
            await disk.DisposeAsync();
            throw;
        }
        content = disk;
        await memory.DisposeAsync();
        lease.Dispose();
        lease = null;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && Interlocked.Exchange(ref disposed, 1) == 0)
        {
            try { content.Dispose(); }
            finally { lease?.Dispose(); lease = null; }
        }
        base.Dispose(disposing);
    }

    public override async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        try { await content.DisposeAsync(); }
        finally { lease?.Dispose(); lease = null; }
        GC.SuppressFinalize(this);
    }
}
