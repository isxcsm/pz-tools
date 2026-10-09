package pztools.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;

/**
 * The local players of this game: the characters a formula may change. {@code IsoPlayer.players} holds the players
 * of this machine (one, or up to four in split screen); a remote player or any other character is not in it. The
 * array is the game's own and final, so the questions below read it as it is and allocate nothing.
 */
final class Players {
    private final Object[] players;
    // IsoGameCharacter.getStats() as (Object)Object; IsoMovingObject.getCurrentSquare() as (Object)Object and
    // IsoGridSquare.isInARoom() as (Object)boolean.
    private final MethodHandle stats, square, inARoom;

    Players(ClassLoader loader) throws ReflectiveOperationException, IllegalAccessException {
        Class<?> player = Game.type(loader, "zombie.characters.IsoPlayer");
        players = (Object[])player.getField("players").get(null);
        stats = Game.exact(Game.type(loader, "zombie.characters.IsoGameCharacter").getMethod("getStats"),
            MethodType.methodType(Object.class, Object.class));
        square = Game.exact(Game.type(loader, "zombie.iso.IsoMovingObject").getMethod("getCurrentSquare"),
            MethodType.methodType(Object.class, Object.class));
        inARoom = Game.exact(Game.type(loader, "zombie.iso.IsoGridSquare").getMethod("isInARoom"),
            MethodType.methodType(boolean.class, Object.class));
    }

    /** The game's own array of this machine's players, by player index (an empty place is null): read, never changed. */
    Object[] all() { return players; }

    /** Whether the player stands in a room (a building's, a basement's), not outdoors. */
    boolean inRoom(Object player) throws Throwable {
        Object at = player == null ? null : square.invokeExact(player);
        return at != null && (boolean)inARoom.invokeExact(at);
    }

    /** Whether the character is a player of this machine. */
    boolean local(Object character) {
        if (character == null) return false;
        for (Object player : players) if (player == character) return true;
        return false;
    }

    /** Whether the stats are those of a player of this machine. */
    boolean ownsStats(Object stats) throws Throwable {
        if (stats == null) return false;
        for (Object player : players) if (player != null && this.stats.invokeExact(player) == stats) return true;
        return false;
    }
}
