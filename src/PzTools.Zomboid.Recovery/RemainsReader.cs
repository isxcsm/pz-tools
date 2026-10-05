using System.Buffers.Binary;
using System.Text;

namespace PzTools.Zomboid.Recovery;

// World 249 only. Length-delimited items/components stay opaque: never recreate modded items.
internal sealed class RemainsReader(byte[] bytes, int position = 0)
{
    public byte[] Bytes { get; } = bytes;
    public int Position { get; private set; } = position;
    public int Remaining => Bytes.Length - Position;
    public void Skip(int length) { Require(length); Position += length; }
    public byte Byte() { Require(1); return Bytes[Position++]; }
    public bool Bool() => Byte() switch { 0 => false, 1 => true, _ => throw Invalid() };
    public short Short() { Require(2); var n = BinaryPrimitives.ReadInt16BigEndian(Bytes.AsSpan(Position)); Position += 2; return n; }
    public ushort UShort() => unchecked((ushort)Short());
    public int Int() { Require(4); var n = BinaryPrimitives.ReadInt32BigEndian(Bytes.AsSpan(Position)); Position += 4; return n; }
    public long Long() { Require(8); var n = BinaryPrimitives.ReadInt64BigEndian(Bytes.AsSpan(Position)); Position += 8; return n; }
    public float Float() { var n = BitConverter.Int32BitsToSingle(Int()); if (!float.IsFinite(n)) throw Invalid(); return n; }
    public int Count(int maximum = 100_000) { var n = Int(); if (n < 0 || n > maximum) throw Invalid(); return n; }
    public string Text() { var n = UShort(); Require(n); var s = new UTF8Encoding(false, true).GetString(Bytes, Position, n); Position += n; return s; }
    public byte[] Slice(int start) => Bytes[start..Position];
    public void Sized() { var n = Count(32 * 1024 * 1024); Skip(n); }
    public void Strings() { for (var n = Count(); n > 0; n--) Text(); }
    public void Map(int valueBytes) { for (var n = Count(); n > 0; n--) { Text(); Skip(valueBytes); } }
    public void Table(int depth = 0)
    {
        if (depth > 16) throw Invalid();
        for (var n = Count(); n > 0; n--) { Value(depth); Value(depth); }
    }
    public RecoveryIdentityMetadata IdentityTable()
    {
        string? token = null; int? primary = null, secondary = null;
        for (var n = Count(); n > 0; n--)
        {
            var keyType = Byte(); string? key = null;
            if (keyType == 0) key = Text(); else { SkipValue(keyType, 0); }
            var type = Byte();
            if (key == "pztools.recovery.id" && type == 0) token = Text();
            else if (key is "pztools.recovery.primary" or "pztools.recovery.secondary" && type == 1)
            {
                var d = BitConverter.Int64BitsToDouble(Long());
                if (double.IsFinite(d) && d == Math.Truncate(d) && d >= int.MinValue && d <= int.MaxValue)
                { if (key.EndsWith("primary", StringComparison.Ordinal)) primary = (int)d; else secondary = (int)d; }
            }
            else SkipValue(type, 0);
        }
        return new(Guid.TryParseExact(token, "D", out var guid) ? guid.ToString("D") : null, primary, secondary);
    }
    private void SkipValue(byte type, int depth)
    { switch (type) { case 0: Text(); break; case 1: Skip(8); break; case 2: Table(depth + 1); break; case 3: Bool(); break; default: throw Invalid(); } }
    private void Value(int depth)
    {
        switch (Byte()) { case 0: Text(); break; case 1: Skip(8); break; case 2: Table(depth + 1); break; case 3: Bool(); break; default: throw Invalid(); }
    }
    private void Require(int length) { if (length < 0 || length > Remaining) throw Invalid(); }
    public static InvalidDataException Invalid() => new("recovery-unsupported-format");
}

internal sealed record RecoveryIdentityMetadata(string? Token = null, int? Primary = null, int? Secondary = null);
internal sealed record SurvivorIdentity(string First, string Last, bool Female)
{
    public string Name => (First + " " + Last).Trim();
    public bool Named => First is not ("" or "None") && Last is not ("" or "None");
}
/// <param name="Lasting">Stable without the skin texture number, which the game renumbers when the
/// character rises: what a player zombie keeps of the character however long it has walked.</param>
internal sealed record Appearance(byte[] Exact, byte[] Stable, bool Distinctive, byte[] Lasting);
internal sealed record CharacterIdentity(float X, float Y, float Z, SurvivorIdentity? Descriptor, Appearance Visual, RecoveryIdentityMetadata Metadata)
{
    public bool Matches(CharacterIdentity other, bool reanimated)
    {
        if (Descriptor is null || other.Descriptor is null || Descriptor.Female != other.Descriptor.Female) return false;
        if (Metadata.Token is not null || other.Metadata.Token is not null)
            return Metadata.Token is not null && Metadata.Token == other.Metadata.Token;
        if (!reanimated && Descriptor.Named && other.Descriptor.Named)
            return Descriptor.Name == other.Descriptor.Name && Visual.Stable.AsSpan().SequenceEqual(other.Visual.Stable);
        // Legacy reanimation discards names. Require the full inherited visual state AND
        // the saved death position; never choose a nearby zombie or use an ID-card item.
        return Visual.Distinctive && other.Visual.Distinctive && X == other.X && Y == other.Y && Z == other.Z && Visual.Exact.AsSpan().SequenceEqual(other.Visual.Exact);
    }
    public static CharacterIdentity Player(byte[] bytes)
    {
        var r = new RemainsReader(bytes); r.Skip(2); var (x, y, z) = RemainsFormat.Moving(r, out var metadata);
        var descriptor = r.Bool() ? RemainsFormat.Descriptor(r) : null;
        return new(x, y, z, descriptor, RemainsFormat.HumanVisual(r), metadata);
    }
}
internal sealed record InventoryGroup(byte[] Encoded, int Count, string Type, int[] Ids);
internal sealed record RemainsInventory(byte[] Header, byte[] Trailer, IReadOnlyList<InventoryGroup> Groups)
{
    public int Count => Groups.Sum(g => g.Count);
}
internal sealed record WornReference(string Location, int Index);
internal sealed record RemainsRecord(int Start, int End, CharacterIdentity Identity, RemainsInventory Inventory,
    IReadOnlyList<WornReference> Worn, bool Reanimated, int CountOffset = 4, int CountWidth = 4, int RecordCount = 0);

internal static class RemainsFormat
{
    public static (float X, float Y, float Z) Moving(RemainsReader r, out RecoveryIdentityMetadata metadata)
    { r.Skip(8); var x = r.Float(); var y = r.Float(); var z = r.Float(); var dir = r.Int(); if (dir is < 0 or > 7) throw RemainsReader.Invalid(); metadata = r.Bool() ? r.IdentityTable() : new(); return (x, y, z); }
    public static SurvivorIdentity Descriptor(RemainsReader r)
    {
        r.Int(); var first = r.Text(); var last = r.Text(); r.Text(); var gender = r.Int(); if (gender is < 0 or > 1) throw RemainsReader.Invalid();
        r.Text(); var extras = r.Int(); if (extras == 1) r.Strings(); else if (extras != 0) throw RemainsReader.Invalid();
        r.Map(4); r.Text(); r.Skip(8); return new(first, last, gender == 1);
    }
    public static Appearance HumanVisual(RemainsReader r)
    {
        var start = r.Position; var flags = r.Byte(); if ((flags & ~126) != 0) throw RemainsReader.Invalid();
        using var stable = new MemoryStream(); stable.WriteByte(flags);
        foreach (var bit in new[] { 4, 2, 8 }) if ((flags & bit) != 0) { var p = r.Position; r.Skip(3); stable.Write(r.Bytes.AsSpan(p, 3)); }
        var skin = (int)stable.Position + 1;
        var p0 = r.Position; r.Skip(2); stable.Write(r.Bytes.AsSpan(p0, 2)); var rot = r.Position; r.Byte();
        foreach (var bit in new[] { 64, 16, 32 }) if ((flags & bit) != 0) { var p = r.Position; r.Text(); stable.Write(r.Bytes.AsSpan(p, r.Position - p)); }
        for (var i = 0; i < 3; i++) r.Skip(r.Byte());
        for (var n = r.Byte(); n > 0; n--) ItemVisual(r);
        r.Text(); var flags2 = r.Byte(); if ((flags2 & ~6) != 0) throw RemainsReader.Invalid();
        stable.WriteByte(flags2); foreach (var bit in new[] { 4, 2 }) if ((flags2 & bit) != 0) { var p = r.Position; r.Skip(3); stable.Write(r.Bytes.AsSpan(p, 3)); }
        // The game rewrites two fields when the character rises: the rot stage, and the skin texture
        // number, which HumanVisual.getSkinTexture clamps to the shorter zombie skin list (human skin 4 of
        // a woman becomes zombie skin 3). Neither can identify the character.
        var exact = r.Slice(start); exact[rot - start] = 255; exact[p0 + 1 - start] = 255;
        var lasting = stable.ToArray(); lasting[skin] = 255;
        // Default/all-zero synthetic visuals cannot establish identity on their own.
        return new(exact, stable.ToArray(), (flags & 14) != 0 && (flags & 48) != 0, lasting);
    }
    public static void ItemVisual(RemainsReader r)
    {
        var flags = r.Byte(); r.Text(); r.Text(); r.Text(); if ((flags & 1) != 0) r.Skip(3); if ((flags & 2) != 0) r.Skip(1);
        if ((flags & 4) != 0) r.Skip(1); if ((flags & 8) != 0) r.Skip(4); if ((flags & 16) != 0) r.Text(); for (var i = 0; i < 6; i++) r.Skip(r.Byte());
    }
    public static RemainsInventory Inventory(RemainsReader r, IReadOnlyDictionary<int, string>? registry)
    {
        var start = r.Position; r.Text(); r.Bool(); var header = r.Slice(start); var n = r.UShort(); if (n > 32767) throw RemainsReader.Invalid();
        var groups = new List<InventoryGroup>(); var ids = new HashSet<int>(); var total = 0;
        for (var i = 0; i < n; i++)
        {
            var p = r.Position; var count = r.Count(32767); var size = r.Count(32 * 1024 * 1024);
            if (count < 1 || size < 8 || total + count > 32767) throw RemainsReader.Invalid();
            var payload = r.Position; r.Skip(size); var itemIds = new int[count]; itemIds[0] = BinaryPrimitives.ReadInt32BigEndian(r.Bytes.AsSpan(payload + 3));
            if (r.Bytes[payload + 2] != 255) throw RemainsReader.Invalid();
            for (var j = 1; j < count; j++) itemIds[j] = r.Int();
            if (itemIds.Any(id => !ids.Add(id))) throw new InvalidDataException("recovery-inventory-ambiguous");
            var type = ""; var registryId = BinaryPrimitives.ReadInt16BigEndian(r.Bytes.AsSpan(payload));
            if (registry is not null && !registry.TryGetValue(registryId, out type)) throw RemainsReader.Invalid();
            groups.Add(new(r.Slice(p), count, type, itemIds)); total += count;
        }
        var tail = r.Position; r.Bool(); r.Int(); return new(header, r.Slice(tail), groups);
    }
    public static void SkipInventory(RemainsReader r) => Inventory(r, null);
    public static List<WornReference> Worn(RemainsReader r, int itemCount)
    {
        var n = r.Byte(); if (n > 127) throw RemainsReader.Invalid(); var result = new List<WornReference>();
        for (var i = 0; i < n; i++) { var where = r.Text(); var index = r.Short(); if (index < -1 || index >= itemCount) throw RemainsReader.Invalid(); result.Add(new(where, index)); }
        return result;
    }
    /// <summary>
    /// The game draws wounds and bandages as clothing worn under everything else: these items, put on and taken
    /// off as a body part changes state during play (IsoGameCharacter.Bandages). Nothing in the game takes them
    /// off for a body part healed outside it, so recovery removes them itself. A bandage that healing keeps gets its
    /// model back from the game, which puts one on any bandaged part without it. No real item uses these names.
    /// </summary>
    public static bool IsBodyModel(string type) =>
        type.StartsWith("Base.Wound_", StringComparison.Ordinal) || type.StartsWith("Base.Bandage_", StringComparison.Ordinal);

    /// <summary>The player without the wound and bandage models of their healed body, worn and held items renumbered.</summary>
    public static byte[] RemoveBodyModels(byte[] player, InventoryLayout layout, IReadOnlyDictionary<int, string> registry)
    {
        var r = new RemainsReader(player, layout.Start);
        var inventory = Inventory(r, registry);
        if (r.Position != layout.End) throw RemainsReader.Invalid();
        if (!inventory.Groups.Any(g => IsBodyModel(g.Type))) return player;
        var w = new RemainsReader(player, layout.WornStart);
        var worn = Worn(w, inventory.Count);
        if (w.Position != layout.WornEnd) throw RemainsReader.Invalid();
        var (wornPrimary, wornSecondary) = (w.Short(), w.Short());
        var (kept, indexMap) = KeepClothes(inventory);
        int Map(int index) => indexMap.TryGetValue(index, out var mapped) ? mapped : -1;
        using var wear = new MemoryStream();
        var still = worn.Where(x => indexMap.ContainsKey(x.Index)).ToArray();
        wear.WriteByte(checked((byte)still.Length));
        foreach (var x in still) { var b = Encoding.UTF8.GetBytes(x.Location); Short(wear, b.Length); wear.Write(b); Short(wear, Map(x.Index)); }
        Short(wear, Map(wornPrimary)); Short(wear, Map(wornSecondary));
        var result = Replace(player, layout.WornStart, layout.WornEnd + 4, wear.ToArray());
        foreach (var hand in new[] { layout.Hands, layout.Hands + 4 })
            BinaryPrimitives.WriteInt32BigEndian(result.AsSpan(hand), Map(BinaryPrimitives.ReadInt32BigEndian(result.AsSpan(hand))));
        return Replace(result, layout.Start, layout.End, kept);
    }

    // The inventory without body models, and each kept item's old index mapped to its new one.
    private static (byte[] Inventory, Dictionary<int, int> IndexMap) KeepClothes(RemainsInventory source)
    {
        var indexMap = new Dictionary<int, int>(); var old = 0; var next = 0;
        using var inventory = new MemoryStream(); inventory.Write(source.Header);
        Short(inventory, source.Groups.Count(g => !IsBodyModel(g.Type)));
        foreach (var group in source.Groups)
        {
            if (!IsBodyModel(group.Type)) { inventory.Write(group.Encoded); for (var i = 0; i < group.Count; i++) indexMap.Add(old + i, next++); }
            old += group.Count;
        }
        inventory.Write(source.Trailer);
        return (inventory.ToArray(), indexMap);
    }

    public static byte[] RestoreInventory(byte[] player, InventoryLayout layout, RemainsRecord source)
    {
        var (kept, indexMap) = KeepClothes(source.Inventory);
        var groups = source.Inventory.Groups.Where(g => !IsBodyModel(g.Type)).ToArray();
        using var worn = new MemoryStream(); var wear = source.Worn.Where(w => indexMap.ContainsKey(w.Index)).ToArray();
        worn.WriteByte(checked((byte)wear.Length)); foreach (var w in wear) { var b = Encoding.UTF8.GetBytes(w.Location); Short(worn, b.Length); worn.Write(b); Short(worn, indexMap[w.Index]); }
        // Prefer stable saved item IDs, never guess a weapon from item type or ordinal.
        // Legacy deaths without these IDs keep hands empty; attachment bytes remain intact.
        var ids = groups.SelectMany(g => g.Ids).ToArray(); var identity = CharacterIdentity.Player(player);
        var primary = identity.Metadata.Primary is { } p && p != -1 ? Array.IndexOf(ids, p) : -1;
        var secondary = identity.Metadata.Secondary is { } q && q != -1 ? Array.IndexOf(ids, q) : -1;
        Short(worn, primary); Short(worn, secondary);
        var result = Replace(player, layout.WornStart, layout.WornEnd + 4, worn.ToArray());
        BinaryPrimitives.WriteInt32BigEndian(result.AsSpan(layout.Hands), primary);
        BinaryPrimitives.WriteInt32BigEndian(result.AsSpan(layout.Hands + 4), secondary);
        return Replace(result, layout.Start, layout.End, kept);
    }
    public static void Short(Stream stream, int value) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteInt16BigEndian(b, checked((short)value)); stream.Write(b); }
    public static byte[] Replace(byte[] bytes, int start, int end, byte[] replacement) => [.. bytes.AsSpan(0, start), .. replacement, .. bytes.AsSpan(end)];
}
