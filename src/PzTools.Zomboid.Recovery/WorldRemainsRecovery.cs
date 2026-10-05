using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using PzTools.Process.Hosting;

namespace PzTools.Zomboid.Recovery;

public enum RemainsKind { Zombie, Corpse }

/// <summary>
/// Remains that may hold a dead character's belongings. <see cref="Key"/> names the record and the exact
/// file content it was found in; recovery refuses it if either has changed since.
/// </summary>
public sealed record RemainsCandidate(string Key, RemainsKind Kind, int Items, int Distance);

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
    private const string ZombieFile = "reanimated.bin";

    /// <summary>
    /// Every record that may be the character's remains, read without holding any file. Records proven
    /// by the recovery ID, a saved name or the exact death position come first; only when there are none
    /// are the save's player zombies (reanimated.bin holds no other zombies) offered by lasting appearance
    /// alone, wherever they have walked. Corpses in map chunks are never matched that loosely: any killed
    /// zombie's corpse is there, and random zombies share the game's few hair and skin colours.
    /// </summary>
    public static async Task<IReadOnlyList<RemainsCandidate>> ListAsync(string save, byte[] player, CancellationToken token) =>
        (await FindAllAsync(save, player, token)).Select(found => found.Candidate).ToArray();

    /// <summary>
    /// The plan for one record, holding its file until the edit is published. With no key, the only
    /// candidate is used; none gives null and several are refused as ambiguous.
    /// </summary>
    public static async Task<RemainsRecoveryPlan?> FindAsync(string save, byte[] player, InventoryLayout layout,
        string? key, CancellationToken token)
    {
        var identity = CharacterIdentity.Player(player);
        if (identity.Descriptor is null) return key is null ? null : throw Changed();
        if (key is null)
        {
            var all = await FindAllAsync(save, player, token);
            if (all.Count == 0) return null;
            if (all.Count > 1) throw new InvalidDataException("recovery-inventory-ambiguous");
            key = all[0].Candidate.Key;
        }
        var (relative, start, hash) = ParseKey(key);
        var registry = await ReadRegistryAsync(save, token) ?? throw Changed();
        var path = Path.Combine(save, relative.Replace('/', Path.DirectorySeparatorChar));
        if (!File.Exists(path)) throw Changed();
        RejectLinks(path);
        FileStream? guard = new(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete, 64 * 1024, FileOptions.Asynchronous);
        try
        {
            if (guard.Length > 64 * 1024 * 1024) throw RemainsReader.Invalid();
            var bytes = new byte[checked((int)guard.Length)]; await guard.ReadExactlyAsync(bytes, token);
            if (Hash(bytes) != hash) throw Changed();
            var chunk = relative != ZombieFile;
            var records = Read(bytes, registry, chunk);
            var record = records.SingleOrDefault(r => r.Start == start) ?? throw Changed();
            // Still the character's by the rules that listed it.
            if (!identity.Matches(record.Identity, record.Reanimated) && (chunk || !LooksLike(identity, record)))
                throw Changed();
            var changed = chunk ? CorpseChunkReader.Remove(bytes, record) : ZombieInventoryRecovery.Remove(bytes, record);
            // Validate framing and CRC after surgery too; unrelated bytes were only shifted.
            Read(changed, registry, chunk);
            var plan = new RemainsRecoveryPlan
            {
                RelativePath = relative,
                OriginalHash = await SaveFileEditTransaction.HashAsync(guard, token),
                UpdatedWorldFile = changed,
                Player = RemainsFormat.RestoreInventory(player, layout, record),
                Items = Items(record),
                Guard = guard,
            };
            guard = null;
            return plan;
        }
        finally { if (guard is not null) await guard.DisposeAsync(); }
    }

    private sealed record Found(RemainsCandidate Candidate, bool Proven);

    private static async Task<List<Found>> FindAllAsync(string save, byte[] player, CancellationToken token)
    {
        var identity = CharacterIdentity.Player(player);
        var found = new List<Found>();
        if (identity.Descriptor is null) return found;
        var registry = await ReadRegistryAsync(save, token);
        if (registry is null) return found;
        var zombies = Path.Combine(save, ZombieFile);
        if (File.Exists(zombies)) Consider(await ReadBoundedAsync(zombies, token), ZombieFile, chunk: false);
        var map = Path.Combine(save, "map");
        if (Directory.Exists(map))
        {
            RejectLinks(map);
            var name = new List<byte>(); foreach (var n in new[] { identity.Descriptor.First, identity.Descriptor.Last })
            { var b = Encoding.UTF8.GetBytes(n); name.Add((byte)(b.Length >> 8)); name.Add((byte)b.Length); name.AddRange(b); }
            var nameBytes = name.ToArray();
            byte[] position = new byte[12]; BinaryPrimitives.WriteSingleBigEndian(position, identity.X);
            BinaryPrimitives.WriteSingleBigEndian(position.AsSpan(4), identity.Y); BinaryPrimitives.WriteSingleBigEndian(position.AsSpan(8), identity.Z);
            var tokenBytes = identity.Metadata.Token is null ? null : Encoding.UTF8.GetBytes(identity.Metadata.Token);
            var chunks = new List<string>();
            foreach (var column in Directory.EnumerateDirectories(map))
            {
                token.ThrowIfCancellationRequested();
                if (!int.TryParse(Path.GetFileName(column), out _)) continue; RejectLinks(column);
                foreach (var path in Directory.EnumerateFiles(column, "*.bin"))
                    if (int.TryParse(Path.GetFileNameWithoutExtension(path), out _)) chunks.Add(path);
            }
            // Thousands of small files: opening them one by one is what takes the time on a cold disk, so
            // several are read at once (930 chunks of a real save, freshly copied: 5.3 s one at a time,
            // 1.1 s eight at a time; warm 0.8 s and 0.35 s). Only the hits are kept, and they are parsed
            // in path order so the result does not depend on timing.
            var hits = new System.Collections.Concurrent.ConcurrentBag<(string Path, byte[] Bytes)>();
            await Parallel.ForEachAsync(chunks, new ParallelOptions { MaxDegreeOfParallelism = 8, CancellationToken = token },
                async (path, cancel) =>
                {
                    RejectLinks(path);
                    // A negative byte prefilter only avoids impossible chunks. Positive hits must
                    // pass the full structural/CRC reader; never carve records from a byte hit.
                    var bytes = await ReadBoundedAsync(path, cancel);
                    if (bytes.AsSpan().IndexOf(nameBytes) >= 0 || bytes.AsSpan().IndexOf(position) >= 0
                        || tokenBytes is not null && bytes.AsSpan().IndexOf(tokenBytes) >= 0)
                        hits.Add((path, bytes));
                });
            foreach (var (path, bytes) in hits.OrderBy(hit => hit.Path, StringComparer.Ordinal))
                Consider(bytes, Path.GetRelativePath(save, path).Replace('\\', '/'), chunk: true);
        }
        // Proof outranks likeness: a lookalike is offered only when nothing is proven.
        return found.Any(f => f.Proven) ? found.Where(f => f.Proven).ToList() : found;

        void Consider(byte[] bytes, string relative, bool chunk)
        {
            string? hash = null;
            foreach (var record in Read(bytes, registry, chunk))
            {
                token.ThrowIfCancellationRequested();
                var proven = identity.Matches(record.Identity, record.Reanimated);
                if (!proven && (chunk || !LooksLike(identity, record))) continue;
                hash ??= Hash(bytes);
                var distance = (int)Math.Round(Math.Sqrt(Math.Pow(record.Identity.X - identity.X, 2) + Math.Pow(record.Identity.Y - identity.Y, 2)));
                found.Add(new(new(string.Join('|', relative, record.Start.ToString(CultureInfo.InvariantCulture), hash),
                    chunk ? RemainsKind.Corpse : RemainsKind.Zombie, Items(record), distance), proven));
            }
        }
    }

    /// <summary>
    /// Without any recovery ID: same sex and the same lasting appearance (hair and skin colour, hair
    /// and beard style, body hair). The dead player's record keeps no clothing, so it cannot be compared;
    /// two characters made from one preset therefore both match, and the user chooses.
    /// </summary>
    private static bool LooksLike(CharacterIdentity player, RemainsRecord record) =>
        player.Metadata.Token is null && record.Identity.Metadata.Token is null
        && player.Descriptor is { } mine && record.Identity.Descriptor is { } theirs && mine.Female == theirs.Female
        && player.Visual.Distinctive && record.Identity.Visual.Distinctive
        && player.Visual.Lasting.AsSpan().SequenceEqual(record.Identity.Visual.Lasting);

    private static IReadOnlyList<RemainsRecord> Read(byte[] bytes, IReadOnlyDictionary<int, string> registry, bool chunk) =>
        chunk ? new CorpseChunkReader(bytes, registry).Read() : ZombieInventoryRecovery.ReadAll(bytes, registry);

    private static int Items(RemainsRecord record) =>
        record.Inventory.Groups.Where(g => !RemainsFormat.IsBodyModel(g.Type)).Sum(g => g.Count);

    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));

    private static InvalidDataException Changed() => new("recovery-remains-changed");

    private static (string Relative, int Start, string Hash) ParseKey(string key)
    {
        var parts = key.Split('|');
        // Only the zombie file or a canonical map chunk; never a path the key could steer elsewhere.
        if (parts.Length != 3 || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var start)
            || parts[2].Length != 64 || !parts[2].All(Uri.IsHexDigit)
            || parts[0] != ZombieFile && !IsChunkPath(parts[0]))
            throw Changed();
        return (parts[0], start, parts[2].ToUpperInvariant());
    }

    private static bool IsChunkPath(string relative)
    {
        var parts = relative.Split('/');
        return parts.Length == 3 && parts[0] == "map"
            && int.TryParse(parts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var x)
            && x.ToString(CultureInfo.InvariantCulture) == parts[1]
            && parts[2].EndsWith(".bin", StringComparison.Ordinal)
            && int.TryParse(parts[2][..^4], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var y)
            && y.ToString(CultureInfo.InvariantCulture) == parts[2][..^4];
    }

    internal static async Task<IReadOnlyDictionary<int, string>?> ReadRegistryAsync(string save, CancellationToken token)
    {
        var registryPath = Path.Combine(save, "WorldDictionary.bin");
        if (!File.Exists(registryPath)) return null;
        RejectLinks(registryPath);
        return WorldItemRegistry.Read(await File.ReadAllBytesAsync(registryPath, token));
    }

    private static async Task<byte[]> ReadBoundedAsync(string path, CancellationToken token)
    {
        // Shared read: listing runs before the edit and must not stand in another reader's way.
        await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024, FileOptions.Asynchronous);
        if (input.Length > 64 * 1024 * 1024) throw RemainsReader.Invalid(); var data = new byte[checked((int)input.Length)]; await input.ReadExactlyAsync(data, token); return data;
    }
    internal static void RejectLinks(string path)
    {
        for (var p = Path.GetFullPath(path); p is not null; p = Path.GetDirectoryName(p))
            if ((File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0) throw new IOException("recovery-linked-path");
    }
}
