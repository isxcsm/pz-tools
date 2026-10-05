using System.Buffers.Binary;

namespace PzTools.Zomboid.State;

/// <summary>
/// Reads IsoPlayer.hoursSurvived from the Build 42 / world-version 249 player blob.
/// The layout is version-specific; unsupported or malformed blobs return no duration.
/// Layout reference: pzmonitor/internal/playersdb/parser.go (MIT), see THIRD_PARTY_NOTICES.md.
/// </summary>
internal static class PlayerBlobDurationReader
{
    public static double? ReadHoursSurvived(byte[]? blob, long worldVersion)
    {
        if (worldVersion != 249 || blob is null || blob.Length is < 128 or > 16 * 1024 * 1024)
            return null;

        try
        {
            var reader = new BlobReader(blob);
            reader.Skip(2 + 4 + 4 + 4 + 4 + 4 + 4); // moving object, offsets, position, direction
            if (reader.Byte() != 0) reader.LuaTable();
            if (reader.Byte() != 0)
            {
                reader.Skip(4);
                reader.String(); // forename
                reader.String(); // surname
                reader.String(); // torso
                reader.Skip(4);
                reader.String(); // profession
                if (reader.Int32() != 0)
                {
                    var count = reader.Count();
                    for (var index = 0; index < count; index++) reader.String();
                }
                var descriptorCount = reader.Count();
                for (var index = 0; index < descriptorCount; index++)
                {
                    reader.String();
                    reader.Skip(4);
                }
                reader.String();
                reader.Skip(8);
            }

            SkipHumanVisual(ref reader);
            SkipInventory(ref reader);
            reader.Skip(1 + 4 + 24 * 4); // asleep, wake-up time, ordered stats
            SkipBodyDamage(ref reader);
            SkipExperience(ref reader);
            reader.Skip(4 + 4 + 1 + 8 * 4); // hand indexes, fire flag, player fields
            var books = reader.Count();
            for (var index = 0; index < books; index++)
            {
                reader.String();
                reader.Skip(4);
            }
            reader.Skip(4);
            var recipes = reader.Count();
            for (var index = 0; index < recipes; index++) reader.String();
            reader.Skip(4 + 3 * 4 + 15);
            var literature = reader.Count();
            for (var index = 0; index < literature; index++)
            {
                reader.String();
                reader.Skip(4);
            }
            var printMedia = reader.Count();
            for (var index = 0; index < printMedia; index++) reader.String();
            reader.Skip(8); // last animal pet
            reader.Skip(reader.Count()); // cheat flags

            var hours = reader.Double();
            var zombieKills = reader.Int32();
            var wornItems = reader.Byte();
            for (var index = 0; index < wornItems; index++)
            {
                reader.String();
                reader.Skip(2);
            }
            reader.Skip(2 + 2);
            var survivorKills = reader.Int32();
            return double.IsFinite(hours) && hours is >= 0 and < 10_000_000
                && zombieKills >= 0 && survivorKills >= 0
                    ? hours : null;
        }
        catch (InvalidDataException)
        {
            return null;
        }
    }

    /// <returns>Where the skin's blood, dirt and holes start: three arrays, each a length byte and one byte per part.</returns>
    internal static int SkipHumanVisual(ref BlobReader reader)
    {
        var flags = reader.Byte();
        if ((flags & 4) != 0) reader.Skip(3);
        if ((flags & 2) != 0) reader.Skip(3);
        if ((flags & 8) != 0) reader.Skip(3);
        reader.Skip(3);
        if ((flags & 0x40) != 0) reader.String();
        if ((flags & 0x10) != 0) reader.String();
        if ((flags & 0x20) != 0) reader.String();
        var skin = reader.Offset;
        for (var index = 0; index < 3; index++) reader.Skip(reader.Byte());
        var visuals = reader.Byte();
        for (var index = 0; index < visuals; index++) SkipItemVisual(ref reader);
        reader.String();
        var extraFlags = reader.Byte();
        if ((extraFlags & 4) != 0) reader.Skip(3);
        if ((extraFlags & 2) != 0) reader.Skip(3);
        return skin;
    }

    internal static void SkipItemVisual(ref BlobReader reader)
    {
        var flags = reader.Byte();
        reader.String();
        reader.String();
        reader.String();
        if ((flags & 1) != 0) reader.Skip(3);
        if ((flags & 2) != 0) reader.Skip(1);
        if ((flags & 4) != 0) reader.Skip(1);
        if ((flags & 8) != 0) reader.Skip(4);
        if ((flags & 0x10) != 0) reader.String();
        for (var index = 0; index < 6; index++) reader.Skip(reader.Byte());
    }

    internal static void SkipInventory(ref BlobReader reader)
    {
        reader.String();
        reader.Skip(1);
        var items = reader.Int16();
        if (items is < 0 or > 100_000) throw new InvalidDataException();
        for (var index = 0; index < items; index++)
        {
            var identical = reader.Int32();
            if (identical is < 0 or > 100_000) throw new InvalidDataException();
            reader.Skip(reader.Int32());
            if (identical > 1) reader.Skip(checked(4 * (identical - 1)));
        }
        reader.Skip(1 + 4);
    }

    private static void SkipBodyDamage(ref BlobReader reader)
    {
        for (var index = 0; index < 17; index++)
        {
            reader.Skip(3);
            var bandaged = reader.Byte();
            reader.Skip(4 + 4);
            if (bandaged != 0) reader.Skip(4);
            if (reader.Byte() != 0) reader.Skip(4);
            reader.Skip(7 * 4 + 3 + 4 + 2 + 4);
            if (reader.Byte() != 0) reader.Skip(4);
            reader.Skip(1 + 4 + 1 + 4);
            reader.String();
            reader.String();
            reader.Skip(6 * 4);
        }
        reader.Skip(4 + 1 + 4 + 4 + 1 + 6 * 4);
        if (reader.Byte() != 0)
        {
            reader.Skip(9 * 4);
            reader.Skip(checked(reader.Count() * 10 * 4));
        }
    }

    internal static void SkipExperience(ref BlobReader reader)
    {
        var traits = reader.Count();
        for (var index = 0; index < traits; index++) reader.String();
        reader.Skip(4 + 4 + 4);
        var xp = reader.Count();
        for (var index = 0; index < xp; index++)
        {
            reader.String();
            reader.Skip(4);
        }
        var levels = reader.Count();
        for (var index = 0; index < levels; index++)
        {
            reader.String();
            reader.Skip(4);
        }
        var multipliers = reader.Count();
        for (var index = 0; index < multipliers; index++)
        {
            reader.String();
            reader.Skip(4 + 2);
        }
    }

    internal ref struct BlobReader
    {
        private readonly ReadOnlySpan<byte> blob;
        private int offset;

        public BlobReader(ReadOnlySpan<byte> blob) => this.blob = blob;

        public int Offset => offset;

        public float Single()
        {
            var value = BitConverter.Int32BitsToSingle(Int32());
            if (!float.IsFinite(value)) throw new InvalidDataException("Non-finite player field.");
            return value;
        }

        public byte Byte()
        {
            Require(1);
            return blob[offset++];
        }

        public int Int16()
        {
            Require(2);
            var value = BinaryPrimitives.ReadInt16BigEndian(blob[offset..]);
            offset += 2;
            return value;
        }

        public int Int32()
        {
            Require(4);
            var value = BinaryPrimitives.ReadInt32BigEndian(blob[offset..]);
            offset += 4;
            return value;
        }

        public double Double()
        {
            Require(8);
            var bits = BinaryPrimitives.ReadInt64BigEndian(blob[offset..]);
            offset += 8;
            return BitConverter.Int64BitsToDouble(bits);
        }

        public int Count()
        {
            var count = Int32();
            if (count is < 0 or > 100_000) throw new InvalidDataException();
            return count;
        }

        public void String()
        {
            var length = Int16();
            Skip(length);
        }

        public string Text()
        {
            var length = Int16();
            Require(length);
            var value = new System.Text.UTF8Encoding(false, true).GetString(blob.Slice(offset, length));
            offset += length;
            return value;
        }

        public void Skip(int length)
        {
            Require(length);
            offset += length;
        }

        private void Require(int length)
        {
            if (length < 0 || length > blob.Length - offset)
                throw new InvalidDataException();
        }

        public void LuaTable(int depth = 0)
        {
            if (depth > 8) throw new InvalidDataException();
            var entries = Count();
            for (var index = 0; index < entries; index++)
            {
                LuaValue(depth);
                LuaValue(depth);
            }
        }

        private void LuaValue(int depth)
        {
            switch (Byte())
            {
                case 0: String(); break;
                case 1: Skip(8); break;
                case 2: LuaTable(depth + 1); break;
                case 3: Skip(1); break;
                default: throw new InvalidDataException();
            }
        }
    }
}
