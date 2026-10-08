package pztools.api;

/**
 * What one frame of the API costs when nothing is declared and no helicopter flies: the game's frame job should find nothing
 * to do. Printed for the report; the bound is for a fault that makes it grow, not a promise.
 */
final class FrameCostTest {
    private static final ClassLoader GAME = FrameCostTest.class.getClassLoader();

    private FrameCostTest() { }

    static void run(String label) {
        for (int frame = 0; frame < 300_000; frame++) GameApi.frame(GAME);
        double best = Double.MAX_VALUE;
        for (int round = 0; round < 5; round++) {
            int frames = 2_000_000;
            long start = System.nanoTime();
            for (int frame = 0; frame < frames; frame++) GameApi.frame(GAME);
            best = Math.min(best, (System.nanoTime() - start) / (double)frames);
        }
        System.out.printf("idle frame of the API (%s): %.1f ns a frame (best of 5 rounds of 2,000,000)%n", label, best);
        if (best > 20_000) throw new AssertionError("An idle frame of the API cost " + best + " ns");
    }
}
