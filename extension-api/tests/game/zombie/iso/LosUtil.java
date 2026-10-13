package zombie.iso;

/** Synthetic: the line of sight between two squares, on the floors between them, as the game asks the squares. */
public final class LosUtil {
    public enum TestResults { Clear, ClearThroughOpenDoor, ClearThroughWindow, Blocked, ClearThroughClosedDoor }

    /** The lines drawn, for the tests. */
    public static int lines;

    /** Along the longer axis one square at a time; the floor changes with the last step. */
    public static TestResults lineClear(IsoCell cell, int x0, int y0, int z0, int x1, int y1, int z1, boolean ignoreDoors) {
        lines++;
        int dx = x1 - x0, dy = y1 - y0;
        int steps = Math.max(1, Math.max(Math.abs(dx), Math.abs(dy)));
        IsoGridSquare last = cell.getGridSquare(x0, y0, z0);
        for (int step = 1; step <= steps; step++) {
            int x = x0 + Math.round((float)dx * step / steps), y = y0 + Math.round((float)dy * step / steps);
            IsoGridSquare next = cell.getGridSquare(x, y, step == steps ? z1 : z0);
            if (next != null && last != null
                    && next.testVisionAdjacent(last.x - next.x, last.y - next.y, last.z - next.z, true, ignoreDoors) == TestResults.Blocked)
                return TestResults.Blocked;
            last = next;
        }
        return TestResults.Clear;
    }
}
