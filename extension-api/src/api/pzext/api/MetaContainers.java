package pzext.api;

import java.lang.reflect.*;
import java.util.*;
import pzext.api.Network.Position;

/**
 * The fluid containers the game keeps running while their squares are not loaded. As a chunk unloads, an object whose
 * fluid container catches rain hands it to a meta entity at the object's position (GameEntityManager.UnregisterEntity,
 * FluidContainer.isQualifiesForMetaStorage); the game's entity engine updates it on the game's thread, as it does the
 * loaded ones (rain in, a petrol leak out), and saves it with the world, position and all; as the square loads, the
 * container goes back to the object. So the API reads, draws from and fills a rain collector far away in the container
 * itself, on the game's thread, as the engine does.
 *
 * Found by position, through an index of the meta entities made again when their number changed (see refresh): a
 * square with none costs a hash lookup. An entry is
 * checked before use: the entity is still the one the game has under its id, and still holds that container (one
 * whose square loaded gave it back; a released entity is pooled and may come back as another).
 */
final class MetaContainers {
    private final Field engine, bucket;
    private final Method system, entities, size, get, x, y, z, component, id, byId;
    private final Class<?> systemType;
    private final Object fluids;
    /** By square: the meta entities there that hold a fluid container, each {entity, container, id}. */
    private Map<Position, List<Object[]>> index = Map.of();
    private int indexed = -1;
    // How many times the index was made: what was read of it (which squares have containers) holds until it moves.
    private int generation;

    private MetaContainers(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> manager = Game.type(loader, "zombie.entity.GameEntityManager");
        Class<?> engineType = Game.type(loader, "zombie.entity.Engine"), entity = Game.type(loader, "zombie.entity.GameEntity");
        Class<?> array = Game.type(loader, "zombie.entity.util.ImmutableArray");
        Class<?> componentType = Game.type(loader, "zombie.entity.ComponentType");
        systemType = Game.type(loader, "zombie.entity.MetaEntitySystem");
        engine = Game.accessible(manager.getDeclaredField("engine"));
        bucket = Game.accessible(systemType.getDeclaredField("metaEntities"));
        system = engineType.getMethod("getSystem", Class.class);
        entities = Game.type(loader, "zombie.entity.EntityBucket").getMethod("getEntities");
        size = array.getMethod("size");
        get = array.getMethod("get", int.class);
        x = entity.getMethod("getX");
        y = entity.getMethod("getY");
        z = entity.getMethod("getZ");
        id = entity.getMethod("getEntityNetID");
        component = entity.getMethod("getComponent", componentType);
        byId = manager.getMethod("GetEntity", long.class);
        fluids = componentType.getField("FluidContainer").get(null);
    }

    /** Null, with a line in the log, for a game whose entities are not as this reads them. */
    static MetaContainers of(ClassLoader loader) {
        try { return new MetaContainers(loader); }
        catch (ReflectiveOperationException | RuntimeException failure) {
            System.err.println("[PZExt] networks: the game's meta entities are out of reach (" + failure
                + "); a rain collector whose square is not loaded counts as last seen");
            return null;
        }
    }

    /**
     * Makes the index again if the number of meta entities changed since it was made: once a second with the grid's
     * work, and before a draw or fill.
     */
    void refresh() throws ReflectiveOperationException {
        Object all = all();
        int count = all == null ? 0 : (int)size.invoke(all);
        if (count != indexed) reindex(all, count);
    }

    /** The number of times the index was made. */
    int generation() { return generation; }

    /** The squares the index lists meta entities with containers at. */
    List<Position> positions() { return List.copyOf(index.keySet()); }

    /** Whether the index lists a meta entity with a container at the square (not checked as {@link #at} does). */
    boolean has(Position at) { return index.containsKey(at); }

    /**
     * The fluid containers meta entities hold at the square, as last indexed, in no order: none while its objects hold
     * them. Stale entries are dropped (see the class comment).
     */
    List<Object> at(Position at) throws ReflectiveOperationException {
        List<Object[]> entries = index.get(at);
        if (entries == null) return List.of();
        var result = new ArrayList<Object>(entries.size());
        for (Iterator<Object[]> each = entries.iterator(); each.hasNext();) {
            Object[] entry = each.next();
            if (byId.invoke(null, (long)entry[2]) == entry[0] && component.invoke(entry[0], fluids) == entry[1]) result.add(entry[1]);
            else each.remove();
        }
        return result;
    }

    /** The meta entities the engine has now (an ImmutableArray); null without a world. */
    private Object all() throws ReflectiveOperationException {
        Object running = engine.get(null);
        Object metas = running == null ? null : system.invoke(running, systemType);
        return metas == null ? null : entities.invoke(bucket.get(metas));
    }

    private void reindex(Object all, int count) throws ReflectiveOperationException {
        var made = new HashMap<Position, List<Object[]>>();
        for (int index = 0; index < count; index++) {
            Object meta = get.invoke(all, index);
            Object container = meta == null ? null : component.invoke(meta, fluids);
            if (container == null) continue;
            var at = new Position((int)Math.floor((float)x.invoke(meta)), (int)Math.floor((float)y.invoke(meta)),
                (int)Math.floor((float)z.invoke(meta)));
            made.computeIfAbsent(at, square -> new ArrayList<>()).add(new Object[] { meta, container, id.invoke(meta) });
        }
        index = made;
        indexed = count;
        generation++;
    }
}
