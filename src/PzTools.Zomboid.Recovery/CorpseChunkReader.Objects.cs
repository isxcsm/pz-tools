namespace PzTools.Zomboid.Recovery;

internal sealed partial class CorpseChunkReader
{
    private void Object()
    {
        if (!r.Bool()) return; var id = r.Byte();
        if (id == 6) { r.Skip(20); r.Sized(); r.Skip(8); var f = r.Byte(); if ((f & ~7) != 0) throw RemainsReader.Invalid(); if ((f & 2) != 0) Entity(); return; }
        if (id == 27) { r.Byte(); r.Skip(checked(r.Byte() * 2)); r.Skip(4); return; }
        if (id == 36) { Animal(); return; }
        // Dynamic players/zombies/vehicles do not belong to the static object collection.
        if (id is 1 or 2 or 3 or 11 or 25 or 30 or 31 or 33 || id > 41) throw RemainsReader.Invalid();
        BaseObject();
        switch (id)
        {
            case 0: case 7: case 20: case 40: break;
            case 4: r.Skip(4); if (r.Bool()) RemainsFormat.SkipInventory(r); break;
            case 5: if (r.Bool()) RemainsFormat.SkipInventory(r); break;
            case 8: r.Skip(14); break;
            case 9: case 10: Radio(); break;
            case 12: r.Skip(14); if (r.Bool()) r.Skip(4); if (r.Bool()) r.Skip(4); break;
            case 13: r.Bool(); break;
            case 14: r.Bool(); r.Skip(4); break;
            case 15: r.Skip(13); break;
            case 16: r.Skip(11); break;
            case 17: r.Skip(25); break;
            case 18: Thumpable(); break;
            case 19: r.Skip(60); r.Text(); r.Text(); if (r.Bool()) r.Sized(); break;
            case 21: if (r.Bool()) r.Sized(); if (r.Bool()) r.Sized(); r.Skip(9); break;
            case 22: r.Skip(14); break;
            case 23: r.Skip(16); break;
            case 24:
                r.Skip(5); r.Text(); r.Text(); RemainsFormat.HumanVisual(r);
                if (r.Bool()) { r.Int(); var inv = RemainsFormat.Inventory(r, null); RemainsFormat.Worn(r, inv.Count); }
                break;
            case 26: r.Skip(10); for (var i = 0; i < 4; i++) if (r.Bool()) r.Skip(4); r.Skip(4); break;
            case 28: r.Skip(2); break;
            case 29: r.Skip(10); if (r.Bool()) { r.Skip(2); if (r.Bool()) r.Text(); r.Skip(20); } r.Skip(12); break;
            case 32: r.Skip(39); break;
            case 34: r.Skip(7); break;
            case 35: r.Skip(6); break;
            case 37: r.Map(4); r.Skip(4); if (r.Bool()) r.Skip(8); r.Bool(); break;
            case 38: Hutch(); break;
            case 39: r.Text(); r.Text(); r.Skip(8); if (r.Bool()) r.Skip(4); r.Skip(9); break;
            case 41: r.Bool(); break;
            default: throw RemainsReader.Invalid();
        }
    }
    private void BaseObject()
    {
        r.Int(); var flags = r.Byte(); if ((flags & 128) != 0) throw RemainsReader.Invalid();
        if ((flags & 1) != 0)
        {
            var n = (flags & 2) != 0 ? 1 : r.Byte(); if (debug) r.Text();
            for (var i = 0; i < n; i++) { r.Int(); var f = r.Byte(); if ((f & 2) != 0) r.Skip(15); if ((f & 16) != 0) r.Skip(4); }
        }
        if ((flags & 4) != 0)
        {
            if (debug) r.Text(); var f = r.Byte();
            if ((f & 4) != 0) r.Byte(); else if ((f & 8) != 0) r.Text();
            if ((f & 16) != 0) r.Int(); else if ((f & 32) != 0) r.Text();
        }
        if ((flags & 8) != 0) r.Skip(3);
        if ((flags & 64) == 0) return;
        var bits = r.UShort(); if ((bits & ~16383) != 0) throw RemainsReader.Invalid();
        if ((bits & 1) != 0) r.Skip(checked(r.Byte() * 8));
        if ((bits & 2) != 0) { if (debug) r.Text(); for (var n = r.Byte(); n > 0; n--) RemainsFormat.SkipInventory(r); }
        if ((bits & 4) != 0) r.Table(); if ((bits & 16) != 0) r.Int(); if ((bits & 64) != 0) r.Skip(4); if ((bits & 128) != 0) r.Skip(4);
        if ((bits & 256) != 0) { if ((bits & 512) != 0) r.Text(); else r.Int(); if ((bits & 1024) != 0) r.Skip(4); }
        if ((bits & 4096) != 0) Entity(); if ((bits & 8192) != 0) r.Text();
    }
    private void Entity()
    { for (var n = r.Byte(); n > 0; n--) { var size = r.Count(32 * 1024 * 1024); if (size < 2) throw RemainsReader.Invalid(); r.Skip(size); } }
    private void Thumpable()
    {
        var f = unchecked((ulong)r.Long());
        foreach (var b in new[] { 3, 4, 5, 6, 7, 20 }) if ((f & (1UL << b)) != 0) r.Skip(4);
        if ((f & (1UL << 21)) != 0) r.Table(); if ((f & (1UL << 22)) != 0) r.Table();
        foreach (var b in new[] { 26, 27, 28, 29 }) if ((f & (1UL << b)) != 0) r.Skip(4);
        if ((f & (1UL << 30)) != 0) r.Skip(2);
        foreach (var b in new[] { 31, 32, 33, 37 }) if ((f & (1UL << b)) != 0) r.Skip(4);
        if ((f & (1UL << 38)) != 0) r.Text(); if ((f & (1UL << 39)) != 0) r.Skip(4); if ((f & (1UL << 42)) != 0) r.Table();
        if ((f >> 43) != 0) throw RemainsReader.Invalid();
    }
    private void Radio()
    {
        if (!r.Bool()) return; r.Text(); r.Skip(48);
        if (r.Bool()) { r.Int(); for (var n = r.Count(); n > 0; n--) { r.Text(); r.Int(); } }
        r.Skip(3); if (r.Bool()) r.Text(); r.Bool();
    }
    private void AnimalGene()
    { r.Int(); r.Text(); for (var a = 0; a < 2; a++) { r.Text(); r.Skip(9); r.Text(); } }
    private void Animal()
    {
        r.Skip(16 + 16 + 96); var type = r.Text(); r.Text(); r.Text(); r.Table(); r.Skip(9);
        for (var n = r.Count(1000); n > 0; n--) AnimalGene(); if (r.Bool()) r.Skip(8);
        r.Skip(28); if (r.Bool()) r.Skip(4); if (r.Bool()) r.Skip(4); r.Skip(14);
        if (type is "lamb" or "ewe" or "ram") r.Skip(4); r.Skip(5); if (type is "hen" or "turkeyhen") r.Skip(4);
        r.Skip(4); r.Skip(checked(r.Count() * 6)); r.Skip(36); r.Text(); r.Skip(4); if (r.Bool()) r.Skip(12); r.Skip(7);
    }
    private void Hutch()
    {
        var x = r.Int(); var y = r.Int(); r.Int(); if (x > 0 && y > 0) return;
        r.Text(); r.Skip(14); r.Sized(); // world249 explicitly frames the complete animal section
        r.Skip(8); for (var n = r.Byte(); n > 0; n--) { for (var eggs = r.Byte(); eggs > 0; eggs--) r.Sized(); if (r.Bool()) Animal(); }
    }
}
