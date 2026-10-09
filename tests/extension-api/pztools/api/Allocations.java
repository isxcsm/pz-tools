package pztools.api;

import java.util.Arrays;

/**
 * What a piece of work allocates on the test's thread, as the steady state of the game would: the median of several rounds.
 *
 * <p>One round of a measuring loop is not enough. When the JIT moves the loop that measures from C1's on-stack-replacement code to
 * C2's, that round alone counts some 9 KB on the thread (about 9120 bytes, the same with an empty loop and no game code in it; never
 * with C1 alone, and in the same round every time with the compilation in the foreground), though nothing in the work allocates.
 * Under the load of the whole suite that move comes late, in any round, so a bound on one round failed now and then. Work that does
 * allocate does so in every round (or in most of them), which the median shows; the move, in one round, it leaves out.
 */
final class Allocations {
    private Allocations() { }

    /** The median of what {@code rounds} runs of the work allocated, in bytes (the measurement's own few hundred included). */
    static long median(int rounds, Runnable work) {
        long[] bytes = new long[rounds];
        for (int round = 0; round < rounds; round++) {
            long start = allocated();
            work.run();
            bytes[round] = allocated() - start;
        }
        Arrays.sort(bytes);
        return bytes[rounds / 2];
    }

    static long allocated() {
        return ((com.sun.management.ThreadMXBean)java.lang.management.ManagementFactory.getThreadMXBean()).getThreadAllocatedBytes(Thread.currentThread().threadId());
    }
}
