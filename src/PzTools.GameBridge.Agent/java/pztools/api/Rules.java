package pztools.api;

import java.util.*;
import java.util.function.Function;
import pztools.api.Network.Position;
import pztools.api.Network.Thing;

/**
 * The networks' object rules (excluded and included objects) by square, as the hooks read them: immutable, read on any
 * thread. Each rule carries what its grid keeps of the rule's network for its answers ({@code T}).
 */
final class Rules<T> {
    /** One network's rule for an object at one square. */
    record Rule<T>(String sprite, boolean included, Network network, T data) { }

    // The squares that have rules, each to its index in at.
    private final SquareMap squares;
    private final List<List<Rule<T>>> at;

    private Rules(SquareMap squares, List<List<Rule<T>>> at) { this.squares = squares; this.at = at; }

    static <T> Rules<T> none() { return new Rules<>(SquareMap.EMPTY, List.of()); }

    /** The rules of the networks, in their order; each network's exclusions before its inclusions. */
    static <T> Rules<T> of(List<Network> networks, Function<Network, T> data) {
        var bySquare = new LinkedHashMap<Position, List<Rule<T>>>();
        for (Network network : networks) {
            T kept = data.apply(network);
            for (Thing thing : network.excluded)
                bySquare.computeIfAbsent(thing.at(), unused -> new ArrayList<>()).add(new Rule<>(thing.sprite(), false, network, kept));
            for (Thing thing : network.included)
                bySquare.computeIfAbsent(thing.at(), unused -> new ArrayList<>()).add(new Rule<>(thing.sprite(), true, network, kept));
        }
        var indices = new HashMap<Position, Long>();
        var at = new ArrayList<List<Rule<T>>>();
        for (var entry : bySquare.entrySet()) {
            indices.put(entry.getKey(), (long)at.size());
            at.add(List.copyOf(entry.getValue()));
        }
        return new Rules<>(new SquareMap(indices), List.copyOf(at));
    }

    boolean isEmpty() { return squares.isEmpty(); }

    /** The rules at a square, whatever their sprites. */
    List<Rule<T>> at(int x, int y, int z) {
        int index = (int)squares.get(x, y, z, -1);
        return index < 0 ? List.of() : at.get(index);
    }

    /**
     * The rules that name the object, or one of its parts for an object that covers several squares, part by part.
     * Empty for nearly every object, and then without allocating: the squares are looked up first, and a sprite is read
     * only on a square that has rules.
     */
    List<Rule<T>> naming(Object object, Game game, Buildings buildings) throws ReflectiveOperationException {
        if (squares.isEmpty()) return List.of();
        if (!game.hasParts(object)) return naming(object, List.of(), game, buildings);
        List<Rule<T>> result = List.of();
        List<Object> parts = game.partsOnThisThread(object);
        for (int index = 0; index < parts.size(); index++) result = naming(parts.get(index), result, game, buildings);
        return result;
    }

    private List<Rule<T>> naming(Object part, List<Rule<T>> result, Game game, Buildings buildings) throws ReflectiveOperationException {
        Object square = game.squareOf(part);
        if (square == null) return result;
        List<Rule<T>> here = at(game.x(square), game.y(square), game.z(square));
        if (here.isEmpty()) return result;
        String sprite = buildings.sprite(part);
        for (Rule<T> rule : here) {
            if (!rule.sprite().equals(sprite)) continue;
            if (result.isEmpty()) result = new ArrayList<>();
            result.add(rule);
        }
        return result;
    }

    /** Whether one of the rules excludes the object from the network. Read by index: an iterator would allocate. */
    static <T> boolean excludes(List<Rule<T>> rules, Network network) {
        for (int index = 0; index < rules.size(); index++)
            if (!rules.get(index).included() && rules.get(index).network() == network) return true;
        return false;
    }
}
