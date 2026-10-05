using System.Buffers.Binary;
using static PzTools.Zomboid.State.PlayerBlobDurationReader;

namespace PzTools.Zomboid.Recovery;

internal sealed record InventoryRecovery(byte[] Player, byte[] Zombies, int Items);

/// <summary>Moves opaque item records. ID cards are ordinary items, never identity credentials.</summary>
internal static class ZombieInventoryRecovery
{
    public static bool IsEmpty(byte[] player, InventoryLayout layout)
    { var r = new BlobReader(player); r.Skip(layout.Start); r.String(); r.Byte(); return r.Int16() == 0; }

    public static IReadOnlyList<RemainsRecord> ReadAll(byte[] bytes, IReadOnlyDictionary<int, string> registry)
    {
        var r = new RemainsReader(bytes); if (r.Int() != 249) throw RemainsReader.Invalid(); var count = r.Count(10000);
        var result = new List<RemainsRecord>();
        for (var i = 0; i < count; i++)
        {
            var start = r.Position; if (!r.Bool() || r.Byte() != 3) throw RemainsReader.Invalid();
            var (x, y, z) = RemainsFormat.Moving(r, out var metadata); var desc = r.Bool() ? RemainsFormat.Descriptor(r) : null;
            var visual = RemainsFormat.HumanVisual(r); var inventory = RemainsFormat.Inventory(r, registry);
            r.Skip(5 + 33); r.Map(4); r.Skip(4); r.Strings(); r.Skip(31); r.Map(4); r.Strings(); r.Skip(8); r.Skip(r.Count());
            if (r.Int() != 1) throw RemainsReader.Invalid(); r.Skip(8); var worn = RemainsFormat.Worn(r, inventory.Count);
            result.Add(new(start, r.Position, new(x, y, z, desc, visual, metadata), inventory, worn, true, RecordCount: count));
        }
        if (r.Remaining != 0) throw RemainsReader.Invalid(); return result;
    }
    public static byte[] Remove(byte[] bytes, RemainsRecord match)
    {
        var remaining = RemainsFormat.Replace(bytes, match.Start, match.End, []);
        BinaryPrimitives.WriteInt32BigEndian(remaining.AsSpan(4), match.RecordCount - 1); return remaining;
    }
    public static InventoryRecovery Recover(byte[] player, InventoryLayout layout, string name,
        byte[] zombies, IReadOnlyDictionary<int, string> registry)
    {
        if (!IsEmpty(player, layout)) throw new InvalidDataException("recovery-inventory-not-empty");
        var identity = CharacterIdentity.Player(player);
        var matches = ReadAll(zombies, registry).Where(z => identity.Matches(z.Identity, true)).ToArray();
        if (matches.Length == 0) throw new InvalidDataException("recovery-inventory-unavailable");
        if (matches.Length != 1) throw new InvalidDataException("recovery-inventory-ambiguous");
        var match = matches[0]; var restored = RemainsFormat.RestoreInventory(player, layout, match);
        return new(restored, Remove(zombies, match), match.Inventory.Groups.Where(g => !RemainsFormat.IsBodyModel(g.Type)).Sum(g => g.Count));
    }
}
