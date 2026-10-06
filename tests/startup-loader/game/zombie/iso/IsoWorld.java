package zombie.iso;

/** Synthetic. */
public final class IsoWorld {
    public static IsoWorld instance = new IsoWorld();
    public final IsoMetaGrid metaGrid = new IsoMetaGrid();
    public IsoCell cell = new IsoCell();
    public IsoMetaGrid getMetaGrid() { return metaGrid; }
    public IsoCell getCell() { return cell; }
}
