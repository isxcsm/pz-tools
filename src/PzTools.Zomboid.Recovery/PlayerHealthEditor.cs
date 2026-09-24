using System.Buffers.Binary;
using PzTools.Zomboid.State;
using static PzTools.Zomboid.State.PlayerBlobDurationReader;

namespace PzTools.Zomboid.Recovery;

/// <summary>
/// Version-gated, surgical edits to the vanilla Build 42.20.4/world 249 layout.
/// No game reset methods are called: some also erase traits or exercise regularity.
/// Unlisted bytes (including mod data, inventory and XP/traits) are copied verbatim.
/// </summary>
public static class PlayerHealthEditor
{
    public static byte[] Heal(byte[] blob, long worldVersion)
        => Heal(blob, worldVersion, out _);

    internal static byte[] Heal(byte[] blob, long worldVersion, out InventoryLayout inventory)
    {
        if (worldVersion != 249 || ReadHoursSurvived(blob, worldVersion) is null)
            throw new InvalidDataException("recovery-unsupported-format");
        var r = new BlobReader(blob);
        var edits = new List<Edit>();
        var inventoryStart = SkipPrefix(ref r);
        var inventoryEnd = r.Offset;
        Replace(ref r, edits, 1 + 4, new byte[5]); // wake up; clear forced wake-up timer
        for (var stat = 0; stat < 24; stat++)
        {
            var offset = r.Offset;
            r.Single();
            if (stat == 5) continue; // FITNESS is not temporary exhaustion. Preserve it.
            edits.Add(new(offset, 4, Float(stat switch { 3 or 10 or 15 => 1, 18 => 37, _ => 0 })));
        }
        for (var part = 0; part < 17; part++) HealBodyPart(ref r, edits);
        var bodyStart = r.Offset;
        r.Single(); Bool(ref r); r.Single(); r.Int32(); Bool(ref r);
        for (var i = 0; i < 6; i++) r.Single();
        var body = new byte[38];
        Float(-1).CopyTo(body, 26); // infectionTime: no infection, not a delayed infection
        Float(-1).CopyTo(body, 30); // infectionMortalityDuration
        edits.Add(new(bodyStart, r.Offset - bodyStart, body));
        if (Bool(ref r)) HealThermal(ref r, edits);

        // This entire region includes both positive AND negative traits, XP, levels and multipliers.
        SkipExperience(ref r);
        var handIndexes = r.Offset;
        r.Skip(8); // hand indexes
        Replace(ref r, edits, 1, [0]); // onFire
        Replace(ref r, edits, 32, new byte[32]); // temporary medicine/sleeping-pill effects
        StringMap(ref r, 4); // read books
        SetFloat(ref r, edits, 0); // infection-reducing medicine timer
        Strings(ref r); // learned recipes
        r.Skip(4); // lastHourSleeped: preserve sleep history
        SetFloat(ref r, edits, 0); // timeSinceLastSmoke; smoker trait remains present
        r.Skip(8); // beard/hair growth history
        for (var i = 0; i < 14; i++) Bool(ref r); // all cheat flags, sneaking: preserve
        Replace(ref r, edits, 1, [0]); // deathDragDown
        StringMap(ref r, 4); // literature
        Strings(ref r); // print media
        r.Skip(8);
        r.Skip(r.Count()); // extra cheat flags
        var hours = r.Double();
        if (!double.IsFinite(hours) || hours < 0) throw new InvalidDataException();
        r.Skip(4); // zombie kills
        var wornStart = r.Offset;
        var worn = r.Byte();
        for (var i = 0; i < worn; i++) { r.String(); r.Skip(2); }
        var wornEnd = r.Offset;
        r.Skip(8); // hands, survivor kills
        r.Skip(20); // nutrition and weight MUST remain unchanged (weight-related traits)
        Bool(ref r); r.String(); r.Skip(12); r.String();
        Bool(ref r); Bool(ref r); Bool(ref r); r.Byte();
        if (Bool(ref r)) r.Skip(10); // saved vehicle position/seat/engine
        r.Skip(checked(r.Count() * 16)); // mechanics history

        ClearMap(ref r, edits, 4); // scheduled exercise stiffness increments
        ClearMap(ref r, edits, 4); // scheduled stiffness timers
        StringMap(ref r, 4); // exercise regularity: trained progress, NOT a debuff
        var pending = r.Offset;
        Strings(ref r);
        edits.Add(new(pending, r.Offset - pending, new byte[4]));
        StringMap(ref r, 8); // exercise timestamps: preserve
        // Validate the tail too, but preserve every byte of book/media/voice/crafting history.
        r.Skip(checked(r.Int16() * 2)); // read-book registry IDs
        var media = r.Int16();
        if (media < 0) throw new InvalidDataException();
        for (var i = 0; i < media; i++) r.String();
        r.Byte(); // voice type
        var crafts = r.Count();
        for (var i = 0; i < crafts; i++)
        {
            r.Skip(checked(r.Count() * 2)); // Java UTF-16 characters
            r.Skip(12); // craft count and last craft time
        }
        if (r.Offset != blob.Length) throw new InvalidDataException("Unsupported player tail.");

        using var output = new MemoryStream(blob.Length);
        var cursor = 0;
        foreach (var edit in edits)
        {
            if (edit.Offset < cursor) throw new InvalidDataException("Overlapping health edits.");
            output.Write(blob.AsSpan(cursor, edit.Offset - cursor));
            output.Write(edit.Bytes);
            cursor = edit.Offset + edit.Length;
        }
        output.Write(blob.AsSpan(cursor));
        var healed = output.ToArray();
        if (ReadHoursSurvived(healed, worldVersion) != hours)
            throw new InvalidDataException("Recovery validation failed.");
        int Translate(int offset) => offset + edits.Where(e => e.Offset < offset).Sum(e => e.Bytes.Length - e.Length);
        inventory = new(Translate(inventoryStart), Translate(inventoryEnd), Translate(handIndexes),
            Translate(wornStart), Translate(wornEnd));
        return healed;
    }

    internal static int SkipPrefix(ref BlobReader r)
    {
        r.Skip(26);
        if (Bool(ref r)) r.LuaTable();
        if (Bool(ref r))
        {
            r.Skip(4); r.String(); r.String(); r.String(); r.Skip(4); r.String();
            if (r.Int32() != 0) Strings(ref r);
            StringMap(ref r, 4);
            r.String(); r.Skip(8);
        }
        SkipHumanVisual(ref r);
        var start = r.Offset;
        SkipInventory(ref r);
        return start;
    }

    private static void HealBodyPart(ref BlobReader r, List<Edit> edits)
    {
        var start = r.Offset;
        Bool(ref r); Bool(ref r); Bool(ref r);
        var bandaged = Bool(ref r);
        for (var i = 0; i < 4; i++) Bool(ref r);
        r.Single();
        if (bandaged) r.Single();
        if (Bool(ref r)) r.Single();
        for (var i = 0; i < 7; i++) r.Single();
        Bool(ref r);
        var bandageXp = r.Byte();
        Bool(ref r); r.Single();
        var stitchXp = r.Byte(); var splintXp = r.Byte();
        r.Single();
        if (Bool(ref r)) r.Single();
        Bool(ref r); r.Single(); Bool(ref r); r.Single();
        r.String(); r.String();
        for (var i = 0; i < 6; i++) r.Single();
        // Unbandaged, uninfected, unsplinted body part; optional fields are omitted.
        var clean = new byte[93];
        Float(100).CopyTo(clean, 8);
        clean[42] = bandageXp; clean[48] = stitchXp; clean[49] = splintXp;
        edits.Add(new(start, r.Offset - start, clean));
    }

    private static void HealThermal(ref BlobReader r, List<Edit> edits)
    {
        foreach (var value in new float[] { 37, 1.5f, 1.5f, 1.5f, 0, 0, 0, 0, 0 })
            SetFloat(ref r, edits, value);
        var count = r.Count();
        if (count != 17) throw new InvalidDataException("Unsupported thermal nodes.");
        var seen = new HashSet<int>();
        for (var i = 0; i < count; i++)
        {
            var type = r.Int32();
            if (type is < 0 or >= 17 || !seen.Add(type)) throw new InvalidDataException();
            SetFloat(ref r, edits, type == 6 ? 37 : 35); // Torso_Upper is the core
            SetFloat(ref r, edits, 33);
            for (var j = 0; j < 3; j++) SetFloat(ref r, edits, 0);
            r.Single(); r.Single(); // clothing insulation/wind resistance: preserve
            SetFloat(ref r, edits, 0); SetFloat(ref r, edits, 0);
        }
    }

    private static void ClearMap(ref BlobReader r, List<Edit> edits, int width)
    {
        var start = r.Offset;
        StringMap(ref r, width);
        edits.Add(new(start, r.Offset - start, new byte[4]));
    }
    private static void StringMap(ref BlobReader r, int width)
    {
        var count = r.Count();
        for (var i = 0; i < count; i++) { r.String(); r.Skip(width); }
    }
    private static void Strings(ref BlobReader r)
    {
        var count = r.Count();
        for (var i = 0; i < count; i++) r.String();
    }
    private static bool Bool(ref BlobReader r) => r.Byte() switch
    {
        0 => false, 1 => true, _ => throw new InvalidDataException("Invalid player flag."),
    };
    private static void Replace(ref BlobReader r, List<Edit> edits, int length, byte[] bytes)
    {
        edits.Add(new(r.Offset, length, bytes)); r.Skip(length);
    }
    private static void SetFloat(ref BlobReader r, List<Edit> edits, float value)
    {
        var offset = r.Offset; r.Single(); edits.Add(new(offset, 4, Float(value)));
    }
    private static byte[] Float(float value)
    {
        var bytes = new byte[4]; BinaryPrimitives.WriteSingleBigEndian(bytes, value); return bytes;
    }
    private sealed record Edit(int Offset, int Length, byte[] Bytes);
}

internal sealed record InventoryLayout(int Start, int End, int Hands, int WornStart, int WornEnd);
