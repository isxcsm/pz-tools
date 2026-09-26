package pztools.extensions.seamless.b4220;

import pztools.extensions.api.SaveProvider;
import pztools.extensions.runtime.CooperativeCapture;
import java.io.IOException;
import java.util.*;

/** One admitted full save, advanced at normal game-loop boundaries. Never pumps UI or waits for disk. */
final class FrameSavePlan implements CooperativeCapture {
    interface World {
        Object currentCell() throws Exception;
        Object[] currentPlayers() throws Exception;
        List<WorldChunkCapture.Chunk> chunks(Object expectedCell) throws Exception;
        default List<WorldChunkCapture.Chunk> chunks(Object expectedCell, List<WorldChunkCapture.Chunk> previous) throws Exception {
            return chunks(expectedCell);
        }
        boolean same(WorldChunkCapture.Chunk chunk) throws Exception;
        boolean dirty(WorldChunkCapture.Chunk chunk) throws Exception;
        MembershipSnapshot membership(WorldChunkCapture.Chunk chunk, long budget) throws Exception;
    }
    interface Saving {
        void chunk(Object chunk) throws Throwable;
        void stage(int stage) throws Throwable;
        void finish(List<WorldChunkCapture.Chunk> chunks) throws Throwable;
    }
    @FunctionalInterface interface Ready {
        boolean get() throws Exception;
        default int blockers(int stage) throws Exception { return get() ? 0 : CaptureReadiness.UNKNOWN; }
    }
    private enum Yield { NONE, BUDGET, FILES, READINESS }
    private final SaveProvider.Context context;
    private final World world;
    private final Saving saving;
    private final Ready ready;
    private final CooperativeChunkWrites writes;
    private final CooperativeChunkWrites.Batch outputs;
    private final SaveSignals.Batch completion;
    private final CaptureTimings timings;
    private final long budget;
    private final Object cell;
    private final Object[] players;
    private final IdentityHashMap<Object, Slot> slots = new IdentityHashMap<>();
    private List<WorldChunkCapture.Chunk> current = List.of();
    private int stage, recaptured;
    private long retained;
    private long refreshEpoch, returnedAt, budgetGap, fileGap, readinessGap;
    private int budgetYields, fileYields, readinessYields;
    private final int[] readinessStages = new int[SaveStageFilter.COUNT], readinessReasons = new int[CaptureReadiness.REASON_COUNT];
    private final long[] readinessStageGaps = new long[SaveStageFilter.COUNT], readinessReasonGaps = new long[CaptureReadiness.REASON_COUNT];
    private int waitingStage, waitingReasons, readinessPrepared;
    private long readinessPreparationNanos;
    private boolean readinessWindowFilled;
    private Yield yielded = Yield.NONE;
    private boolean sealed;
    private final long expires = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(60);
    private static final class Slot {
        final WorldChunkCapture.Chunk target;
        CooperativeChunkWrites.Ticket ticket;
        MembershipSnapshot membership;
        int retries;
        long seen;
        Slot(WorldChunkCapture.Chunk target) { this.target = target; }
    }
    FrameSavePlan(SaveProvider.Context context, World world, Saving saving, Ready ready,
                  CooperativeChunkWrites writes, CooperativeChunkWrites.Batch outputs,
                  SaveSignals.Batch completion, CaptureTimings timings, long budget) throws Exception {
        this.context = context; this.world = world; this.saving = saving; this.ready = ready;
        this.writes = writes; this.outputs = outputs; this.completion = completion;
        this.timings = timings; this.budget = budget;
        cell = world.currentCell(); players = world.currentPlayers();
        if (cell == null) throw new IOException("No world to capture");
        timings.start(); timings.pause(); completion.capturing(false);
    }
    @Override public boolean advance(long budgetNanos) throws Exception {
        context.requireGameThread();
        if (sealed) return true;
        long started = System.nanoTime();
        if (returnedAt != 0) {
            long gap = Math.max(0, started - returnedAt);
            switch (yielded) {
                case BUDGET -> budgetGap += gap;
                case FILES -> fileGap += gap;
                case READINESS -> {
                    readinessGap += gap; readinessStageGaps[waitingStage] += gap;
                    for (int reason = 0; reason < readinessReasons.length; reason++)
                        if ((waitingReasons & (1 << reason)) != 0) readinessReasonGaps[reason] += gap;
                }
                default -> { }
            }
        }
        yielded = Yield.NONE;
        long until = System.nanoTime() + Math.max(1, budgetNanos);
        timings.resume(); completion.capturing(true);
        try {
            while (true) {
                validateCapture(); // A preserved callback may change the world even within one frame.
                if (stage < 3) saving.stage(stage++);
                else if (stage == 3) {
                    if (!awaitReadiness(until)) return false;
                    if (!captureChunks(until)) return false;
                    stage++;
                } else if (stage < SaveStageFilter.VEHICLES) {
                    if (stage == SaveStageFilter.CELL && !awaitReadiness(until)) return false;
                    saving.stage(stage++);
                } else {
                    // Final validation and player/vehicle capture cannot yield between them.
                    if (!awaitReadiness(until)) return false;
                    if (!captureChunks(until)) return false;
                    validateCapture();
                    saving.finish(current);
                    sealed = true; completion.arm();
                    return true;
                }
                // Each original operation is indivisible. Start another only within the remaining budget.
                if (System.nanoTime() >= until) return yieldFor(Yield.BUDGET);
            }
        } catch (Throwable failure) {
            if (failure instanceof Exception exception) throw exception;
            throw (Error)failure;
        } finally { completion.capturing(false); timings.pause(); returnedAt = System.nanoTime(); }
    }
    private void validateCapture() throws Exception {
        if (completion.problem() != null) throw new IOException("Save error observed during capture", completion.problem());
        if (System.nanoTime() >= expires) throw new IOException("Cooperative capture timed out without committing a backup");
        if (world.currentCell() != cell || !samePlayers(players, world.currentPlayers()))
            throw new IOException("World or local character changed during capture");
    }
    private boolean awaitReadiness(long until) throws Exception {
        int reasons = ready.blockers(stage);
        if (reasons == 0) { readinessWindowFilled = false; return true; }
        waitingStage = stage; waitingReasons = reasons;
        readinessStages[stage]++;
        for (int reason = 0; reason < readinessReasons.length; reason++)
            if ((reasons & (1 << reason)) != 0) readinessReasons[reason]++;
        if (!readinessWindowFilled && System.nanoTime() < until) {
            long started = System.nanoTime();
            try {
                // File baselines alone may overlap a vanilla worker. Never call the chunk serializer,
                // touch its shared buffer or advance a save stage while the readiness guard is false.
                refresh();
                readinessWindowFilled = true;
                for (var chunk : current) {
                    if (System.nanoTime() >= until) { readinessWindowFilled = false; break; }
                    Slot slot = slots.get(chunk.object());
                    if (slot.membership != null || slot.ticket != null) continue;
                    slot.ticket = outputs.prepare(chunk.x(), chunk.y());
                    if (slot.ticket == null) break;
                    readinessPrepared++;
                }
            } finally { readinessPreparationNanos += System.nanoTime() - started; }
        }
        return yieldFor(Yield.READINESS);
    }
    private boolean yieldFor(Yield reason) {
        yielded = reason;
        switch (reason) {
            case BUDGET -> budgetYields++;
            case FILES -> fileYields++;
            case READINESS -> readinessYields++;
            default -> { }
        }
        return false;
    }
    private static boolean samePlayers(Object[] expected, Object[] actual) {
        if (expected.length != actual.length) return false;
        for (int i = 0; i < actual.length; i++) if (actual[i] != expected[i]) return false;
        return true;
    }
    private void refresh() throws Exception {
        List<WorldChunkCapture.Chunk> next = world.chunks(cell, current);
        if (next.isEmpty()) throw new IOException("No loaded chunks at the save boundary");
        long epoch = ++refreshEpoch;
        for (var chunk : next) {
            Slot slot = slots.get(chunk.object());
            if (slot == null || !world.same(slot.target)) {
                if (slot != null) release(slot);
                slots.put(chunk.object(), slot = new Slot(chunk));
            }
            slot.seen = epoch;
        }
        for (var iterator = slots.values().iterator(); iterator.hasNext();) {
            Slot old = iterator.next();
            if (old.seen != epoch) { release(old); iterator.remove(); }
        }
        current = next;
    }
    private void release(Slot slot) {
        if (slot.ticket != null && !slot.ticket.finished) slot.ticket.cancel();
        if (slot.membership != null) retained -= slot.membership.retainedBytes();
    }
    private void invalidate(Slot slot) throws IOException {
        if (++slot.retries > 8) throw new IOException("Chunk capture did not converge without blocking gameplay");
        recaptured++;
        if (slot.ticket != null && !slot.ticket.finished) slot.ticket.cancel();
        if (slot.membership != null) retained -= slot.membership.retainedBytes();
        slot.membership = null; slot.ticket = null;
    }
    private boolean captureChunks(long until) throws Throwable {
        refresh();
        while (true) {
            if (outputs.failure.get() != null) throw new IOException("Chunk I/O failed", outputs.failure.get());
            int captured = 0, prepared = 0;
            boolean missing = false;
            // Consume prepared inputs first; never wait for an earlier unready ticket.
            for (var chunk : current) {
                Slot slot = slots.get(chunk.object());
                if (slot.ticket != null && slot.ticket.finished) {
                    if (slot.ticket.failure != null) throw new IOException("Chunk file preparation failed", slot.ticket.failure);
                    if (slot.ticket.conflict) invalidate(slot);
                }
                if (slot.membership != null) continue;
                if (slot.ticket == null || !slot.ticket.ready || slot.ticket.finished) { missing = true; continue; }
                if (!world.same(chunk)) throw new IOException("Chunk reused before capture");
                writes.bind(slot.ticket);
                try { saving.chunk(chunk.object()); }
                finally { writes.unbind(slot.ticket); }
                slot.membership = world.membership(chunk, budget - retained);
                retained += slot.membership.retainedBytes();
                captured++;
                if (System.nanoTime() >= until) return yieldFor(Yield.BUDGET);
            }
            if (!missing && outputs.settled()) {
                boolean unchanged = true;
                for (Slot slot : slots.values()) {
                    if (slot.ticket != null && slot.ticket.conflict || !world.same(slot.target)
                            || world.dirty(slot.target) || !slot.membership.unchanged()) {
                        invalidate(slot); unchanged = false;
                    }
                }
                if (unchanged) return true;
            }
            // Fill the bounded I/O window ahead of capture. A full window is a yield, never a join.
            for (var chunk : current) {
                Slot slot = slots.get(chunk.object());
                if (slot.membership != null || slot.ticket != null) continue;
                slot.ticket = outputs.prepare(chunk.x(), chunk.y());
                if (slot.ticket == null) break;
                prepared++;
                if (System.nanoTime() >= until) return yieldFor(Yield.BUDGET);
            }
            if (prepared == 0 && captured == 0) return yieldFor(Yield.FILES);
            if (System.nanoTime() >= until) return yieldFor(Yield.BUDGET);
        }
    }
    @Override public void abort(Throwable failure) {
        if (sealed) return;
        completion.fail(failure); completion.capturing(false);
        sealed = true; completion.arm();
    }
    @Override public long retainedBytes() { return retained + outputs.retainedBytes(); }
    @Override public String diagnostics() {
        return timings.finish() + "; captureSteps=cooperative; recapturedChunks=" + recaptured
            + "; captureYieldStatsV1=" + budgetYields + "," + budgetGap / 1000 + ","
            + fileYields + "," + fileGap / 1000 + "," + readinessYields + "," + readinessGap / 1000
            + "; readinessStageStatsV1=" + stageReadiness(3) + "," + stageReadiness(SaveStageFilter.CELL) + "," + stageReadiness(SaveStageFilter.VEHICLES)
            + "; readinessReasonStatsV1=" + reasonReadiness()
            + "; readinessPrefetchV1=" + readinessPrepared + "," + readinessPreparationNanos / 1000
            + "; " + completion.diagnostics();
    }
    private String stageReadiness(int value) { return readinessStages[value] + "," + readinessStageGaps[value] / 1000; }
    private String reasonReadiness() {
        var result = new StringBuilder();
        for (int reason = 0; reason < readinessReasons.length; reason++) {
            if (reason != 0) result.append(',');
            result.append(readinessReasons[reason]).append(',').append(readinessReasonGaps[reason] / 1000);
        }
        return result.toString();
    }
    @Override public SaveProvider.Completion completion() { return completion.completion(); }
    @Override public void commit() throws Exception {
        if (!sealed) throw new IllegalStateException("Cannot commit an incomplete capture");
        completion.commit();
    }
    @Override public void close() throws Exception {
        try {
            if (!sealed) abort(new IOException("Capture closed before it completed"));
            completion.close();
        } finally { slots.clear(); current = List.of(); retained = 0; }
    }
}
