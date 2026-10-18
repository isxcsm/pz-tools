package zombie.iso;

/**
 * Synthetic: the world. Its cell is stored in {@code currentCell} by the methods that start and leave a world, as the game's
 * ({@code init}, {@code KillCell}); a test changes the world through {@link #setCell}.
 */
public final class IsoWorld {
    public static IsoWorld instance = new IsoWorld();
    public IsoMetaGrid metaGrid = new IsoMetaGrid();
    public IsoCell currentCell = new IsoCell();
    public final Helicopter helicopter = new Helicopter();
    /** Set by a test: the meta grid cannot be read. */
    public boolean brokenMetaGrid;
    public IsoMetaGrid getMetaGrid() {
        if (brokenMetaGrid) throw new IllegalStateException("the meta grid is broken");
        return metaGrid;
    }
    public IsoCell getCell() { return currentCell; }
    /** What init and KillCell do to the cell: store it. */
    public void setCell(IsoCell next) { currentCell = next; }
}
