using System.Buffers.Binary;

namespace PzTools.Zomboid.Recovery;

/// <summary>Structural world-249 chunk reader. Never byte-carves an object from an item's opaque payload.</summary>
internal sealed partial class CorpseChunkReader(byte[] bytes, IReadOnlyDictionary<int, string> registry)
{
    private readonly RemainsReader r = new(bytes);
    private readonly List<RemainsRecord> bodies = [];
    private bool debug;
    private int minLevel, maxLevel;
    public IReadOnlyList<RemainsRecord> Read()
    {
        debug = r.Bool(); if (r.Int() != 249 || r.Int() != bytes.Length) throw RemainsReader.Invalid();
        var expected = r.Long(); if (expected != Crc(bytes.AsSpan(17))) throw new InvalidDataException("recovery-invalid-chunk");
        r.Bool(); var modified = r.Byte(); var partial = r.Bool(); if (partial && modified != 15) r.Skip(4);
        r.Bool(); r.Byte(); r.Skip(checked(r.UShort() * 12));
        maxLevel = r.Int(); minLevel = r.Int(); if (minLevel < -32 || maxLevel > 31 || maxLevel < minLevel) throw RemainsReader.Invalid();
        r.Skip(checked(r.Count(1000) * 9));
        for (var x = 0; x < 8; x++) for (var y = 0; y < 8; y++)
        {
            var flags = unchecked((ulong)r.Long());
            for (var z = -32; z < 32; z++) if ((flags & (1UL << (z + 32))) != 0)
            {
                if (z < minLevel || z > maxLevel) throw RemainsReader.Invalid();
                Square();
            }
        }
        if (r.Bool()) r.Skip(17); // erosion chunk stamp/epoch/moisture/minerals/soil
        r.Skip(checked(r.UShort() * 9));
        // World 249 writes vehicles to vehicles.db, not this legacy inline section.
        if (r.UShort() != 0) throw RemainsReader.Invalid();
        r.Skip(4); r.Skip(checked(r.UShort() * 8));
        if (r.Remaining != 0) throw RemainsReader.Invalid();
        return bodies;
    }
    private void Square()
    {
        ErosionSquare(); var flags = r.Byte(); if ((flags & 128) != 0) throw RemainsReader.Invalid();
        if ((flags & 1) != 0)
        {
            if (debug) r.Text(); var count = (flags & 2) != 0 ? 2 : (flags & 4) != 0 ? 3 : (flags & 8) != 0 ? r.UShort() : 1;
            if (count > 10000) throw RemainsReader.Invalid();
            for (var i = 0; i < count; i++)
            {
                var begin = r.Position; var size = debug ? r.Int() : 0; r.Byte(); if (debug) r.Text();
                Object(); if (debug && r.Position - begin != size) throw RemainsReader.Invalid();
            }
            if (debug && r.Int() != 0x43525053) throw RemainsReader.Invalid();
        }
        if ((flags & 64) != 0)
        {
            var extra = r.Byte(); if ((extra & ~31) != 0) throw RemainsReader.Invalid();
            if ((extra & 1) != 0)
            {
                if (debug) r.Text(); var countOffset = r.Position; var count = r.UShort(); if (count > 10000) throw RemainsReader.Invalid();
                for (var i = 0; i < count; i++)
                {
                    var start = r.Position; if (debug) r.Text();
                    var body = Corpse(); if (body is not null) bodies.Add(body with { Start = start, CountOffset = countOffset, CountWidth = 2, RecordCount = count });
                }
            }
            if ((extra & 2) != 0) r.Table(); if ((extra & 8) != 0) r.Skip(12);
        }
        if (r.Byte() > 15) throw RemainsReader.Invalid();
    }
    private RemainsRecord? Corpse()
    {
        var start = r.Position; if (!r.Bool() || r.Byte() != 11) throw RemainsReader.Invalid();
        var (x, y, z) = RemainsFormat.Moving(r, out var metadata); var female = r.Bool(); var wasZombie = r.Bool(); var animal = r.Bool();
        if (animal) { r.Text(); r.Skip(4); for (var n = r.Byte(); n > 0; n--) AnimalGene(); for (var n = r.Byte(); n > 0; n--) r.Text(); r.Text(); r.Text(); r.Skip(4); r.Text(); r.Skip(12); }
        r.Skip(3); // ObjectIDShort: short id followed by type
        if (r.Bool()) throw new InvalidDataException("recovery-singleplayer-only");
        r.Int(); var descriptor = r.Bool() ? RemainsFormat.Descriptor(r) : null;
        var visualType = r.Byte(); Appearance? visual = null;
        if (visualType == 0) visual = RemainsFormat.HumanVisual(r); else if (visualType == 1) { r.Text(); r.Byte(); } else throw RemainsReader.Invalid();
        RemainsInventory? inventory = null; List<WornReference> worn = [];
        if (r.Bool())
        {
            r.Int(); inventory = RemainsFormat.Inventory(r, registry); worn = RemainsFormat.Worn(r, inventory.Count);
            // Attached item IDs/slot metadata survive in opaque records and original hotbar modData.
            RemainsFormat.Worn(r, inventory.Count);
        }
        r.Float(); r.Float(); var flags = r.Byte(); if ((flags & ~3) != 0) throw RemainsReader.Invalid();
        r.Bool(); r.Float(); r.Byte(); r.Byte(); r.Text(); r.Text(); r.Bool(); r.Bool();
        if (r.Bool()) r.Skip(checked(r.Count(1024) * 44));
        if (animal || visual is null) return null;
        inventory ??= new RemainsInventory([0, 4, (byte)'n', (byte)'o', (byte)'n', (byte)'e', 0], new byte[5], []);
        if (descriptor is not null && descriptor.Female != female) throw RemainsReader.Invalid();
        return new(start, r.Position, new(x, y, z, descriptor, visual, metadata), inventory, worn, wasZombie);
    }
    public static byte[] Remove(byte[] original, RemainsRecord body)
    {
        if (body.CountWidth != 2 || body.RecordCount < 1) throw RemainsReader.Invalid();
        var remaining = RemainsFormat.Replace(original, body.Start, body.End, []);
        BinaryPrimitives.WriteInt16BigEndian(remaining.AsSpan(body.CountOffset), checked((short)(body.RecordCount - 1)));
        BinaryPrimitives.WriteInt32BigEndian(remaining.AsSpan(5), remaining.Length);
        BinaryPrimitives.WriteInt64BigEndian(remaining.AsSpan(9), Crc(remaining.AsSpan(17)));
        return remaining;
    }
    internal static uint Crc(ReadOnlySpan<byte> data)
    {
        var crc = uint.MaxValue;
        foreach (var value in data) { crc ^= value; for (var i = 0; i < 8; i++) crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320U : 0); }
        return ~crc;
    }
    private void ErosionSquare()
    {
        var flags = r.Byte(); if ((flags & 1) == 0) return; r.Skip(3);
        var count = (flags & 4) != 0 ? 1 : (flags & 8) != 0 ? 2 : (flags & 16) != 0 ? 3 : (flags & 32) != 0 ? 4 : (flags & 64) != 0 ? r.Byte() : 0;
        for (var i = 0; i < count; i++)
        {
            var id = (r.Byte() << 8) | r.Byte(); r.Byte(); var f = r.Byte(); if ((f & 128) != 0) r.Byte(); r.Byte(); // category game-object field
            switch (id)
            {
                case 0: case 1: r.Skip(3); break;
                case 2: r.Skip(2); break;
                case 3: r.Skip(4); break;
                case 0x100: r.Skip(8); break;
                case 0x200: r.Skip(7); if (r.Bool()) r.Skip(7); break;
                case 0x201: r.Skip(10); if (r.Bool()) r.Skip(11); break;
                case 0x300: break;
                default: throw RemainsReader.Invalid();
            }
        }
    }
}
