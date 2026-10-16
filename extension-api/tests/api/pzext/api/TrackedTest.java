package pzext.api;

import java.util.ArrayList;
import java.util.ConcurrentModificationException;
import java.util.List;
import pzext.boot.Tracked;

/**
 * The game lists the hooks put in ({@link Tracked}): a view of one ({@code subList}) can be written like the game's own, and what it
 * writes goes through the list's methods, so that its version counts every change.
 */
final class TrackedTest {
    private TrackedTest() { }

    static void run() {
        var list = new Tracked(Tracked.ITEMS, null, List.of("a", "b", "c", "d", "e"));
        int version = list.version;
        List<Object> view = list.subList(1, 4);
        check(view.size() == 3 && view.get(0).equals("b") && view.get(2).equals("d"), "The view is " + view);
        view.set(0, "B");
        check(list.get(1).equals("B") && list.version > version, "A change through the view's set was not counted");
        version = list.version;
        view.add("x");
        check(list.equals(List.of("a", "B", "c", "d", "x", "e")) && view.size() == 4 && list.version > version,
            "An add through the view was lost: " + list);
        version = list.version;
        check(view.remove(1).equals("c") && list.equals(List.of("a", "B", "d", "x", "e")) && view.size() == 3 && list.version > version,
            "A remove through the view was lost: " + list);
        version = list.version;
        var inner = view.subList(0, 2);
        inner.clear();
        check(list.equals(List.of("a", "x", "e")) && view.size() == 1 && inner.isEmpty() && list.version > version,
            "A clear through a view of the view was lost: " + list + " " + view);
        version = list.version;
        var each = view.iterator();
        each.next();
        each.remove();
        check(list.equals(List.of("a", "e")) && view.isEmpty() && list.version > version, "An iterator's remove through the view was lost: " + list);
        version = list.version;
        view.addAll(List.of("p", "q"));
        check(list.equals(List.of("a", "p", "q", "e")) && list.version >= version + 2, "An addAll through the view was lost: " + list);
        version = list.version;
        check(view.removeIf("p"::equals) && list.equals(List.of("a", "q", "e")) && list.version > version, "A removeIf through the view was lost: " + list);

        // As the game's: a change made to the list another way cuts the view off, and a range outside the list is refused.
        list.add("y");
        try { view.size(); throw new AssertionError("A view went on after the list changed another way"); }
        catch (ConcurrentModificationException expected) { }
        try { list.subList(2, 9); throw new AssertionError("A view past the end was made"); }
        catch (IndexOutOfBoundsException expected) { }
        check(list.subList(1, 3).equals(new ArrayList<>(list).subList(1, 3)), "A view is not equal to the same part of a copy");
    }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
