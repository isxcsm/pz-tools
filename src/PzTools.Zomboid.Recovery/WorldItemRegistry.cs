using static PzTools.Zomboid.State.PlayerBlobDurationReader;

namespace PzTools.Zomboid.Recovery;

/// <summary>Reads the authoritative dictionary, not the optional human-readable Lua export.</summary>
internal static class WorldItemRegistry
{
    public static IReadOnlyDictionary<int, string> Read(byte[] bytes)
    {
        var r = new BlobReader(bytes);
        if (r.Int32() != 1) throw new InvalidDataException("recovery-unsupported-dictionary");
        r.Skip(7); // next item, object and sprite IDs
        var mods = Strings(ref r);
        var modules = Strings(ref r);
        var result = new Dictionary<int, string>();
        var count = r.Count();
        for (var i = 0; i < count; i++)
        {
            var id = r.Int16();
            var module = Index(ref r, modules);
            var name = r.Text();
            var flags = r.Byte();
            if ((flags & 1) != 0) Index(ref r, mods);
            if ((flags & 16) != 0)
            {
                var overrides = (flags & 32) != 0 ? r.Byte() : 1;
                for (var j = 0; j < overrides; j++) Index(ref r, mods);
            }
            if (id < 0 || !result.TryAdd(id, module + "." + name)) throw new InvalidDataException();
        }
        // Entity, sprite and script dictionaries follow. They are neither read nor modified.
        return result;
    }

    private static string[] Strings(ref BlobReader r)
    {
        var result = new string[r.Count()];
        for (var i = 0; i < result.Length; i++) result[i] = r.Text();
        return result;
    }

    private static string Index(ref BlobReader r, string[] values)
    {
        var index = values.Length > 127 ? r.Int16() : r.Byte();
        if ((uint)index >= values.Length) throw new InvalidDataException();
        return values[index];
    }
}
