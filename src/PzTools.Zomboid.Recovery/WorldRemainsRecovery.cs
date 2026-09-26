using System.Buffers.Binary;
using System.Text;
using PzTools.Process.Hosting;

namespace PzTools.Zomboid.Recovery;

internal sealed class RemainsRecoveryPlan : IAsyncDisposable
{
    public required string RelativePath { get; init; }
    public required string OriginalHash { get; init; }
    public required byte[] UpdatedWorldFile { get; init; }
    public required byte[] Player { get; init; }
    public required int Items { get; init; }
    public required FileStream Guard { get; init; }
    public ValueTask DisposeAsync() => Guard.DisposeAsync();
}

internal static class WorldRemainsRecovery
{
    public static async Task<RemainsRecoveryPlan?> FindAsync(string save, byte[] player, InventoryLayout layout,
        CancellationToken token)
    {
        var identity = CharacterIdentity.Player(player);
        if (identity.Descriptor is null) return null;
        var registryPath = Path.Combine(save, "WorldDictionary.bin");
        if (!File.Exists(registryPath)) return null;
        RejectLinks(registryPath);
        var registry = WorldItemRegistry.Read(await File.ReadAllBytesAsync(registryPath, token));
        RemainsRecoveryPlan? found = null;
        try
        {
            var zombies = Path.Combine(save, "reanimated.bin");
            if (File.Exists(zombies)) await ConsiderAsync(zombies, "reanimated.bin", false);
            var map = Path.Combine(save, "map");
            if (Directory.Exists(map))
            {
                RejectLinks(map);
                var name = new List<byte>(); foreach (var n in new[] { identity.Descriptor.First, identity.Descriptor.Last })
                { var b = Encoding.UTF8.GetBytes(n); name.Add((byte)(b.Length >> 8)); name.Add((byte)b.Length); name.AddRange(b); }
                byte[] position = new byte[12]; BinaryPrimitives.WriteSingleBigEndian(position, identity.X);
                BinaryPrimitives.WriteSingleBigEndian(position.AsSpan(4), identity.Y); BinaryPrimitives.WriteSingleBigEndian(position.AsSpan(8), identity.Z);
                foreach (var column in Directory.EnumerateDirectories(map))
                {
                    token.ThrowIfCancellationRequested();
                    if (!int.TryParse(Path.GetFileName(column), out _)) continue; RejectLinks(column);
                    foreach (var path in Directory.EnumerateFiles(column, "*.bin"))
                    {
                        token.ThrowIfCancellationRequested(); if (!int.TryParse(Path.GetFileNameWithoutExtension(path), out _)) continue;
                        RejectLinks(path);
                        // A negative byte prefilter only avoids impossible chunks. Positive hits must
                        // pass the full structural/CRC reader; never carve records from a byte hit.
                        var bytes = await ReadBoundedAsync(path, token);
                        if (bytes.AsSpan().IndexOf(name.ToArray()) < 0 && bytes.AsSpan().IndexOf(position) < 0
                            && (identity.Metadata.Token is null || bytes.AsSpan().IndexOf(Encoding.UTF8.GetBytes(identity.Metadata.Token)) < 0)) continue;
                        await ConsiderAsync(path, Path.GetRelativePath(save, path).Replace('\\', '/'), true);
                    }
                }
            }
            return found;
        }
        catch { if (found is not null) await found.DisposeAsync(); throw; }

        async Task ConsiderAsync(string path, string relative, bool chunk)
        {
            RejectLinks(path); FileStream? guard = new(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete, 64 * 1024, FileOptions.Asynchronous);
            try
            {
                if (guard.Length > 64 * 1024 * 1024) throw RemainsReader.Invalid();
                var bytes = new byte[checked((int)guard.Length)]; await guard.ReadExactlyAsync(bytes, token);
                var records = chunk ? new CorpseChunkReader(bytes, registry).Read() : ZombieInventoryRecovery.ReadAll(bytes, registry);
                foreach (var record in records)
                {
                    token.ThrowIfCancellationRequested(); if (!identity.Matches(record.Identity, record.Reanimated)) continue;
                    if (found is not null) throw new InvalidDataException("recovery-inventory-ambiguous");
                    var changed = chunk ? CorpseChunkReader.Remove(bytes, record) : ZombieInventoryRecovery.Remove(bytes, record);
                    // Validate framing and CRC after surgery too; unrelated bytes were only shifted.
                    if (chunk) new CorpseChunkReader(changed, registry).Read(); else ZombieInventoryRecovery.ReadAll(changed, registry);
                    if (guard is null) throw RemainsReader.Invalid();
                    found = new()
                    {
                        RelativePath = relative,
                        OriginalHash = await SaveFileEditTransaction.HashAsync(guard, token),
                        UpdatedWorldFile = changed,
                        Player = RemainsFormat.RestoreInventory(player, layout, record),
                        Items = record.Inventory.Groups.Where(g => !g.Type.StartsWith("Base.Wound_", StringComparison.Ordinal)).Sum(g => g.Count),
                        Guard = guard
                    };
                    guard = null;
                }
            }
            finally { if (guard is not null) await guard.DisposeAsync(); }
        }
    }
    private static async Task<byte[]> ReadBoundedAsync(string path, CancellationToken token)
    {
        await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.Asynchronous);
        if (input.Length > 64 * 1024 * 1024) throw RemainsReader.Invalid(); var data = new byte[checked((int)input.Length)]; await input.ReadExactlyAsync(data, token); return data;
    }
    internal static void RejectLinks(string path)
    {
        for (var p = Path.GetFullPath(path); p is not null; p = Path.GetDirectoryName(p))
            if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new IOException("recovery-linked-path");
    }
}
