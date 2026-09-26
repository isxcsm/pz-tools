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
        boolean same(WorldChunkCapture.Chunk chunk) throws Exception;
        boolean dirty(WorldChunkCapture.Chunk chunk) throws Exception;
        MembershipSnapshot membership(WorldChunkCapture.Chunk chunk, long budget) throws Exception;
    }
    interface Saving {
        void chunk(Object chunk) throws Throwable;
        void stage(int stage) throws Throwable;
        void finish(List<WorldChunkCapture.Chunk> chunks) throws Throwable;
    }
    @FunctionalInterface interface Ready { boolean get() throws Exception; }
    private static final int MAXIMUM_CHUNKS_PER_STEP = 4;
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
    private IdentityHashMap<Object, Slot> slots = new IdentityHashMap<>();
    private List<WorldChunkCapture.Chunk> current = List.of();
    private int stage, recaptured;
    private long retained;
    private boolean sealed;
    private final long expires = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(60);
    private static final class Slot {
        final WorldChunkCapture.Chunk target;
        CooperativeChunkWrites.Ticket ticket;
        MembershipSnapshot membership;
        int retries;
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
        if (completion.problem() != null) throw new IOException("Save error observed during capture", completion.problem());
        if (System.nanoTime() >= expires) throw new IOException("Cooperative capture timed out without committing a backup");
        if (world.currentCell() != cell || !samePlayers(players, world.currentPlayers()))
            throw new IOException("World or local character changed during capture");
        long until = System.nanoTime() + Math.max(1, budgetNanos);
        timings.resume(); completion.capturing(true);
        try {
            if (stage < 3) { saving.stage(stage++); return false; }
            if (stage == 3) {
                if (!ready.get()) return false;
                if (captureChunks(until)) stage++;
                return false;
            }
            if (stage < SaveStageFilter.VEHICLES) {
                if (stage == SaveStageFilter.CELL && !ready.get()) return false;
                saving.stage(stage++); return false;
            }
            // Inventory membership and all player/vehicle captures share this final game-thread turn.
            if (!ready.get() || !captureChunks(until)) return false;
            saving.finish(current);
            sealed = true; completion.arm();
            return true;
        } catch (Throwable failure) {
            if (failure instanceof Exception exception) throw exception;
            throw (Error)failure;
        } finally { completion.capturing(false); timings.pause(); }
    }
    private static boolean samePlayers(Object[] expected, Object[] actual) {
        if (expected.length != actual.length) return false;
        for (int i = 0; i < actual.length; i++) if (actual[i] != expected[i]) return false;
        return true;
    }
    private void refresh() throws Exception {
        List<WorldChunkCapture.Chunk> next = world.chunks(cell);
        if (next.isEmpty()) throw new IOException("No loaded chunks at the save boundary");
        var nextSlots = new IdentityHashMap<Object, Slot>();
        for (var chunk : next) {
            Slot slot = slots.get(chunk.object());
            if (slot == null || !world.same(slot.target)) slot = new Slot(chunk);
            nextSlots.put(chunk.object(), slot);
        }
        for (Slot old : slots.values()) if (nextSlots.get(old.target.object()) != old) {
            if (old.ticket != null) old.ticket.cancel();
            if (old.membership != null) retained -= old.membership.retainedBytes();
        }
        slots = nextSlots; current = next;
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
        if (outputs.failure.get() != null) throw new IOException("Chunk I/O failed", outputs.failure.get());
        int captured = 0;
        for (var chunk : current) {
            Slot slot = slots.get(chunk.object());
            if (slot.ticket != null && slot.ticket.finished) {
                if (slot.ticket.failure != null) throw new IOException("Chunk file preparation failed", slot.ticket.failure);
                if (slot.ticket.conflict) invalidate(slot);
            }
            if (slot.membership != null) continue;
            if (slot.ticket == null) slot.ticket = outputs.prepare(chunk.x(), chunk.y());
            if (slot.ticket == null || !slot.ticket.ready || slot.ticket.finished) continue;
            if (!world.same(chunk)) throw new IOException("Chunk reused before capture");
            writes.bind(slot.ticket);
            try { saving.chunk(chunk.object()); }
            finally { writes.unbind(slot.ticket); }
            long remaining = budget - retained;
            slot.membership = world.membership(chunk, remaining);
            retained += slot.membership.retainedBytes();
            captured++;
            if (captured >= MAXIMUM_CHUNKS_PER_STEP || System.nanoTime() >= until) break;
        }
        if (!outputs.settled()) return false;
        for (Slot slot : slots.values()) if (slot.membership == null) return false;
        boolean unchanged = true;
        for (Slot slot : slots.values()) {
            if (slot.ticket != null && slot.ticket.conflict || !world.same(slot.target)
                    || world.dirty(slot.target) || !slot.membership.unchanged()) {
                invalidate(slot); unchanged = false;
            }
        }
        return unchanged;
    }
    @Override public void abort(Throwable failure) {
        if (sealed) return;
        completion.fail(failure); completion.capturing(false);
        sealed = true; completion.arm();
    }
    @Override public long retainedBytes() { return retained + outputs.retainedBytes(); }
    @Override public String diagnostics() {
        return timings.finish() + "; captureSteps=cooperative; recapturedChunks=" + recaptured;
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
