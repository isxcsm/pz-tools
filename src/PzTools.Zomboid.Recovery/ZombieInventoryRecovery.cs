using System.Buffers.Binary;
using System.Text;
using static PzTools.Zomboid.State.PlayerBlobDurationReader;

namespace PzTools.Zomboid.Recovery;

internal sealed record InventoryRecovery(byte[] Player, byte[] Zombies, int Items);

/// <summary>
/// World 249 only. Moves opaque item records and remaps worn indexes; it never recreates items
/// from their type names (which would lose condition, mod data and bag contents).
/// A matching ID card AND identical saved position are required. No nearest-zombie heuristic.
/// </summary>
internal static class ZombieInventoryRecovery
{
    public static bool IsEmpty(byte[] player, InventoryLayout layout)
    {
        var r = new BlobReader(player);
        r.Skip(layout.Start); r.String(); r.Byte();
        return r.Int16() == 0;
    }

    public static InventoryRecovery Recover(byte[] player, InventoryLayout layout, string name,
        byte[] zombies, IReadOnlyDictionary<int, string> registry)
    {
        if (!IsEmpty(player, layout)) throw new InvalidDataException("recovery-inventory-not-empty");
        var r = new BlobReader(zombies);
        if (r.Int32() != 249) throw new InvalidDataException("recovery-unsupported-format");
        var count = r.Count();
        Zombie? match = null;
        for (var i = 0; i < count; i++)
        {
            var zombie = ReadZombie(ref r, zombies, registry);
            // IsoMovingObject stores x/y/z after the two factory bytes and two offset floats.
            var samePosition = zombies.AsSpan(zombie.Start + 10, 12).SequenceEqual(player.AsSpan(10, 12));
            var cards = zombie.Groups.Where(g => g.Type == "Base.IDcard").ToArray();
            if (!samePosition || cards.Length != 1 || cards[0].Count != 1) continue;
            var cardName = ReadCustomName(cards[0].Payload);
            // Vanilla ID cards use a translated label, a colon, then the full character name.
            if (cardName is null || !cardName.EndsWith(": " + name, StringComparison.Ordinal)) continue;
            if (match is not null) throw new InvalidDataException("recovery-inventory-ambiguous");
            match = zombie;
        }
        if (r.Offset != zombies.Length) throw new InvalidDataException("recovery-unsupported-format");
        if (match is null) throw new InvalidDataException("recovery-inventory-unavailable");

        var indexMap = new Dictionary<int, int>();
        var groups = new List<Group>();
        var oldIndex = 0;
        var newIndex = 0;
        foreach (var group in match.Groups)
        {
            // These are visual overlays created by zombification, not normal clothing or traits.
            if (!group.Type.StartsWith("Base.Wound_", StringComparison.Ordinal))
            {
                groups.Add(group);
                for (var i = 0; i < group.Count; i++) indexMap.Add(oldIndex + i, newIndex++);
            }
            oldIndex += group.Count;
        }
        using var inventory = new MemoryStream();
        inventory.Write(zombies.AsSpan(match.InventoryStart, match.GroupsStart - match.InventoryStart));
        WriteShort(inventory, groups.Count);
        foreach (var group in groups) inventory.Write(zombies.AsSpan(group.Start, group.End - group.Start));
        inventory.Write(zombies.AsSpan(match.InventoryEnd - 5, 5));
        using var worn = new MemoryStream();
        var wornItems = match.Worn.Where(w => indexMap.ContainsKey(w.Index)).ToArray();
        worn.WriteByte(checked((byte)wornItems.Length));
        foreach (var item in wornItems)
        {
            var text = Encoding.UTF8.GetBytes(item.Location);
            WriteShort(worn, text.Length); worn.Write(text); WriteShort(worn, indexMap[item.Index]);
        }

        // Patch from high to low offsets so earlier offsets stay valid. Hands cannot be inferred
        // from the zombie: preserve the items, but do not invent equipped hand references.
        var restored = Replace(player, layout.WornStart, layout.WornEnd + 4, [.. worn.ToArray(), 255, 255, 255, 255]);
        restored.AsSpan(layout.Hands, 8).Fill(255);
        restored = Replace(restored, layout.Start, layout.End, inventory.ToArray());
        if (!PlayerHealthEditor.Heal(restored, 249).AsSpan().SequenceEqual(restored))
            throw new InvalidDataException("recovery-validation-failed");
        var remaining = Replace(zombies, match.Start, match.End, []);
        BinaryPrimitives.WriteInt32BigEndian(remaining.AsSpan(4), count - 1);
        return new(restored, remaining, newIndex);
    }

    private static Zombie ReadZombie(ref BlobReader r, byte[] bytes, IReadOnlyDictionary<int, string> registry)
    {
        var start = r.Offset;
        // Build 42 factory IDs: 1 = player, 3 = zombie. Other object types are not editable here.
        if (bytes.Length - start < 2 || bytes[start] != 1 || bytes[start + 1] != 3)
            throw new InvalidDataException("recovery-unsupported-format");
        var inventoryStart = PlayerHealthEditor.SkipPrefix(ref r);
        var inventoryEnd = r.Offset;
        var inv = new BlobReader(bytes);
        inv.Skip(inventoryStart); inv.String(); inv.Byte();
        var groupsStart = inv.Offset;
        var groupCount = inv.Int16();
        if (groupCount < 0) throw new InvalidDataException();
        var groups = new List<Group>();
        var items = 0;
        var ids = new HashSet<int>();
        for (var i = 0; i < groupCount; i++)
        {
            var groupStart = inv.Offset;
            var count = inv.Count();
            var length = inv.Int32();
            if (count == 0 || length < 8 || items + count > short.MaxValue) throw new InvalidDataException();
            var payloadStart = inv.Offset;
            inv.Skip(length);
            var payload = bytes[payloadStart..inv.Offset];
            var id = BinaryPrimitives.ReadInt16BigEndian(payload);
            if (!registry.TryGetValue(id, out var type) || payload[2] != 255) throw new InvalidDataException();
            if (!ids.Add(BinaryPrimitives.ReadInt32BigEndian(payload.AsSpan(3)))) throw new InvalidDataException();
            for (var j = 1; j < count; j++) if (!ids.Add(inv.Int32())) throw new InvalidDataException();
            groups.Add(new(groupStart, inv.Offset, count, type, payload));
            items += count;
        }
        inv.Skip(5);
        if (inv.Offset != inventoryEnd) throw new InvalidDataException();
        r.Skip(5); // asleep / forced wake time; zombies omit Stats, BodyDamage, XP and hand indexes
        r.Skip(1 + 32); // onFire and medicine
        SkipMap(ref r); r.Skip(4); SkipStrings(ref r);
        r.Skip(16 + 15); // sleep/smoke/hair timing and flags
        SkipMap(ref r); SkipStrings(ref r); r.Skip(8); r.Skip(r.Count());
        if (r.Int32() != 1) throw new InvalidDataException("recovery-unsupported-format");
        r.Skip(8); // timeSinceSeenFlesh, zombie flags
        var wornCount = r.Byte();
        if (wornCount > 127) throw new InvalidDataException();
        var worn = new List<Worn>();
        for (var i = 0; i < wornCount; i++)
        {
            var location = r.Text(); var index = r.Int16();
            // Multi-item body locations (notably base:wound) legitimately repeat. The game
            // also writes -1 when a worn item is no longer in its saved inventory list.
            if (index < -1 || index >= items) throw new InvalidDataException();
            worn.Add(new(location, index));
        }
        return new(start, r.Offset, inventoryStart, inventoryEnd, groupsStart, groups, worn);
    }

    private static string? ReadCustomName(byte[] item)
    {
        var r = new BlobReader(item); r.Skip(7);
        var flags = r.Byte();
        if ((flags & 1) != 0) r.Skip(4);
        if ((flags & 4) != 0) r.Skip(1);
        if ((flags & 8) != 0) SkipItemVisual(ref r);
        if ((flags & 16) != 0) r.Skip(4);
        if ((flags & 32) != 0) r.Skip(4);
        if ((flags & 64) == 0) return null;
        var extended = r.Int32();
        if ((extended & 1) != 0) r.LuaTable();
        if ((extended & 4) != 0) r.Skip(2);
        return (extended & 8) != 0 ? r.Text() : null;
    }

    private static void SkipMap(ref BlobReader r)
    { var count = r.Count(); for (var i = 0; i < count; i++) { r.String(); r.Skip(4); } }
    private static void SkipStrings(ref BlobReader r)
    { var count = r.Count(); for (var i = 0; i < count; i++) r.String(); }
    private static void WriteShort(Stream stream, int value)
    { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteInt16BigEndian(b, checked((short)value)); stream.Write(b); }
    private static byte[] Replace(byte[] bytes, int start, int end, byte[] replacement)
        => [.. bytes.AsSpan(0, start), .. replacement, .. bytes.AsSpan(end)];
    private sealed record Group(int Start, int End, int Count, string Type, byte[] Payload);
    private sealed record Worn(string Location, int Index);
    private sealed record Zombie(int Start, int End, int InventoryStart, int InventoryEnd, int GroupsStart,
        List<Group> Groups, List<Worn> Worn);
}
