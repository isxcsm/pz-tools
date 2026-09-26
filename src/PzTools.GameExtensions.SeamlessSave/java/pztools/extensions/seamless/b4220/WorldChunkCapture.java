package pztools.extensions.seamless.b4220;

import java.io.IOException;
import java.lang.reflect.*;
import java.util.*;

/** B42.20 game-thread view. Coordinates and closed byte inputs alone reach the I/O worker. */
final class WorldChunkCapture implements FrameSavePlan.World {
    record Chunk(Object object, int x, int y, short load) { }
    private final Field world, cell, maps, players, playerCount, gridWidth, x, y, squares, dirty;
    private final Method getChunk, loadId, containerCount, containerAt, items, nestedInventory, worldItem;
    private final Method[] squareLists;
    private final Class<?> objectType, inventoryContainer, worldItemType;
    private final Set<Object> seenChunks = Collections.newSetFromMap(new IdentityHashMap<>());
    WorldChunkCapture(ClassLoader loader) throws Exception {
        Class<?> worldType = Class.forName("zombie.iso.IsoWorld", false, loader);
        Class<?> cellType = Class.forName("zombie.iso.IsoCell", false, loader);
        Class<?> playerType = Class.forName("zombie.characters.IsoPlayer", false, loader);
        Class<?> mapType = Class.forName("zombie.iso.IsoChunkMap", false, loader);
        Class<?> chunkType = Class.forName("zombie.iso.IsoChunk", false, loader);
        Class<?> squareType = Class.forName("zombie.iso.IsoGridSquare", false, loader);
        world = worldType.getField("instance"); cell = worldType.getField("currentCell");
        maps = cellType.getField("chunkMap"); players = playerType.getField("players");
        playerCount = playerType.getField("numPlayers"); gridWidth = mapType.getField("chunkGridWidth");
        getChunk = mapType.getMethod("getChunk", int.class, int.class);
        x = chunkType.getField("wx"); y = chunkType.getField("wy");
        squares = chunkType.getField("squares"); dirty = chunkType.getField("requiresHotSave");
        loadId = chunkType.getMethod("getLoadID");
        objectType = Class.forName("zombie.iso.IsoObject", false, loader);
        containerCount = objectType.getMethod("getContainerCount");
        containerAt = objectType.getMethod("getContainerByIndex", int.class);
        items = Class.forName("zombie.inventory.ItemContainer", false, loader).getMethod("getItems");
        inventoryContainer = Class.forName("zombie.inventory.types.InventoryContainer", false, loader);
        nestedInventory = inventoryContainer.getMethod("getInventory");
        worldItemType = Class.forName("zombie.iso.objects.IsoWorldInventoryObject", false, loader);
        worldItem = worldItemType.getMethod("getItem");
        squareLists = new Method[] { squareType.getMethod("getObjects"), squareType.getMethod("getSpecialObjects"),
            squareType.getMethod("getWorldObjects"), squareType.getMethod("getStaticMovingObjects") };
    }
    public Object currentCell() throws Exception {
        Object instance = world.get(null); return instance == null ? null : cell.get(instance);
    }
    public Object[] currentPlayers() throws Exception {
        int count = playerCount.getInt(null);
        Object[] array = (Object[])players.get(null);
        if (count < 1 || count > 4 || array == null || count > array.length) throw new IOException("Local players changed");
        return Arrays.copyOf(array, count);
    }
    public List<Chunk> chunks(Object expectedCell) throws Exception {
        return chunks(expectedCell, List.of());
    }
    public List<Chunk> chunks(Object expectedCell, List<Chunk> previous) throws Exception {
        if (currentCell() != expectedCell) throw new IOException("World changed during capture");
        int width = gridWidth.getInt(null), count = playerCount.getInt(null);
        Object[] array = (Object[])maps.get(expectedCell);
        if (width < 1 || width > 64 || count < 1 || count > array.length) throw new IOException("Unsupported chunk grid");
        ArrayList<Chunk> changed = null;
        int index = 0;
        try {
            for (int player = 0; player < count; player++) for (int a = 0; a < width; a++) for (int b = 0; b < width; b++) {
                Object chunk = getChunk.invoke(array[player], a, b);
                if (chunk == null || !seenChunks.add(chunk)) continue;
                if (index >= 4096) throw new IOException("Too many loaded chunks for bounded capture");
                Chunk prior = index < previous.size() ? previous.get(index) : null;
                if (prior == null || prior.object() != chunk || !same(prior)) {
                    if (changed == null) changed = new ArrayList<>(previous.subList(0, index));
                    changed.add(new Chunk(chunk, x.getInt(chunk), y.getInt(chunk), (short)loadId.invoke(chunk)));
                } else if (changed != null) changed.add(prior);
                index++;
            }
            if (changed != null) return changed;
            return index == previous.size() ? previous : new ArrayList<>(previous.subList(0, index));
        } finally { seenChunks.clear(); } // Reuse capacity without retaining a departed world.
    }
    public boolean same(Chunk chunk) throws Exception {
        return x.getInt(chunk.object()) == chunk.x() && y.getInt(chunk.object()) == chunk.y()
            && (short)loadId.invoke(chunk.object()) == chunk.load();
    }
    public boolean dirty(Chunk chunk) throws Exception { return dirty.getBoolean(chunk.object()); }
    public MembershipSnapshot membership(Chunk chunk, long budget) throws Exception {
        if (!same(chunk)) throw new IOException("Chunk was reused before serialization");
        var snapshot = new MembershipSnapshot(budget);
        Object[] rows = snapshot.array(() -> squares.get(chunk.object()));
        var objects = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        var containers = Collections.newSetFromMap(new IdentityHashMap<Object, Boolean>());
        var pending = new ArrayDeque<Object>();
        for (int row = 0; row < rows.length; row++) {
            final int index = row;
            Object[] entries = snapshot.array(() -> rows[index]);
            for (Object square : entries) if (square != null) {
                for (Method accessor : squareLists) {
                    Object[] list = snapshot.list(() -> accessor.invoke(square));
                    for (Object object : list) if (object != null && objects.add(object)) {
                        if (!objectType.isInstance(object)) throw new IOException("Unknown serialized world object");
                        snapshot.value(() -> containerCount.invoke(object));
                        int count = (int)containerCount.invoke(object);
                        if (count < 0 || count > 1024) throw new IOException("Unsupported container count");
                        for (int container = 0; container < count; container++) {
                            final int slot = container;
                            Object value = snapshot.reference(() -> containerAt.invoke(object, slot));
                            if (value != null) pending.add(value);
                        }
                        if (worldItemType.isInstance(object)) {
                            Object item = snapshot.reference(() -> worldItem.invoke(object));
                            addNested(item, snapshot, pending);
                        }
                    }
                }
            }
        }
        while (!pending.isEmpty()) {
            Object container = pending.removeFirst();
            if (!containers.add(container)) continue;
            Object[] list = snapshot.list(() -> items.invoke(container));
            for (Object item : list) addNested(item, snapshot, pending);
        }
        return snapshot;
    }
    private void addNested(Object item, MembershipSnapshot snapshot, ArrayDeque<Object> pending) throws Exception {
        if (inventoryContainer.isInstance(item)) {
            Object value = snapshot.reference(() -> nestedInventory.invoke(item));
            if (value != null) pending.add(value);
        }
    }
}
