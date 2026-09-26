package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import pztools.extensions.runtime.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.concurrent.locks.*;

/** Actual frame plan and bounded disk worker; no live game, UI gating or timing threshold. */
public final class CooperativeCaptureTest {
    /** The game's PZArrayList supports indexed access but deliberately rejects iterators. */
    private static final class IndexedList<E> extends AbstractList<E> implements RandomAccess {
        private final List<E> values = new ArrayList<>();
        @Override public int size() { return values.size(); }
        @Override public E get(int index) { return values.get(index); }
        @Override public boolean add(E value) { return values.add(value); }
        @Override public E set(int index, E value) { return values.set(index, value); }
        @Override public void clear() { values.clear(); }
        @Override public Iterator<E> iterator() { throw new UnsupportedOperationException(); }
        @Override public ListIterator<E> listIterator() { throw new UnsupportedOperationException(); }
        @Override public ListIterator<E> listIterator(int index) { throw new UnsupportedOperationException(); }
    }
    private static final class Chunk {
        final int x; final List<Object> items = new IndexedList<>();
        short load = 1;
        Chunk(int x) { this.x = x; }
    }
    public static void run() throws Exception {
        indexedCollectionsKeepTransferChecks();
        Path root = Files.createTempDirectory("pztools-frame-save-");
        ReentrantLock fileGate = new ReentrantLock();
        AtomicInteger references = new AtomicInteger(), captured = new AtomicInteger(), finalPlayer = new AtomicInteger(-1);
        AtomicBoolean mutation = new AtomicBoolean(), ended = new AtomicBoolean();
        List<Chunk> chunks = new ArrayList<>();
        Object cell = new Object(), player = new Object(), item = new Object();
        List<Object> inventory = new ArrayList<>();
        int[] stages = new int[SaveStageFilter.COUNT];
        for (int i=0;i<361;i++) { chunks.add(new Chunk(i)); Files.write(root.resolve(i+".bin"), new byte[4]); }
        chunks.getFirst().items.add(item);
        var access = new OwnedChunkWrites.Access() {
            public java.io.File destination(int x,int y) { return root.resolve(x+".bin").toFile(); }
            public OwnedChunkWrites.LockReference reserve(int x,int y) {
                references.incrementAndGet();
                return new OwnedChunkWrites.LockReference() {
                    public Lock writeLock() { return fileGate; }
                    public void close() { references.decrementAndGet(); }
                };
            }
            public void synchronous(int x,int y,ByteBuffer bytes) throws Exception {
                Files.write(root.resolve(x+".bin"), Arrays.copyOf(bytes.array(),bytes.position()));
            }
        };
        try (var io = new CooperativeChunkWrites(access); var runtime = new CheckpointRuntime(1024*1024)) {
            var context = new SaveProvider.Context("frame", "process", "world", root, Thread.currentThread(), CooperativeCaptureTest.class.getClassLoader());
            var signals = new SaveSignals(); signals.register();
            try {
                var world = new FrameSavePlan.World() {
                    public Object currentCell() { return ended.get() ? null : cell; }
                    public Object[] currentPlayers() { return new Object[]{player}; }
                    public List<WorldChunkCapture.Chunk> chunks(Object expected) {
                        return chunks.stream().map(c -> new WorldChunkCapture.Chunk(c,c.x,0,(short)1)).toList();
                    }
                    public boolean same(WorldChunkCapture.Chunk c) { return chunks.get(c.x())==c.object(); }
                    public boolean dirty(WorldChunkCapture.Chunk c) { return false; }
                    public MembershipSnapshot membership(WorldChunkCapture.Chunk c,long limit) throws Exception {
                        var result=new MembershipSnapshot(limit); result.list(() -> ((Chunk)c.object()).items); return result;
                    }
                };
                var saving = new FrameSavePlan.Saving() {
                    public void stage(int stage) { stages[stage]++; }
                    public void chunk(Object value) throws Exception {
                        var c=(Chunk)value; io.write(c.x,0,ByteBuffer.allocate(4).putInt(c.items.size())); captured.incrementAndGet();
                        if (captured.get() == 4 && mutation.compareAndSet(false, true)) {
                            chunks.getFirst().items.clear(); inventory.add(item);
                        }
                    }
                    public void finish(List<WorldChunkCapture.Chunk> current) {
                        finalPlayer.set(inventory.size()); stages[SaveStageFilter.VEHICLES]++;
                    }
                };
                var provider = new SaveProvider() {
                    public String id() { return "fixture.cooperative"; }
                    public Support inspect(Context ignored) { return new Support(true,null); }
                    public PreparedSave capture(Context c,long budget) throws Exception {
                        var completion=signals.begin(c,false);
                        completion.cooperative=io.begin(c,budget/2,completion::fail);
                        return new FrameSavePlan(c,world,saving,() -> true,io,completion.cooperative,completion,new CaptureTimings(),budget/2);
                    }
                };
                var job=runtime.begin(provider,context);
                // File ownership is blocked, yet frame dispatch returns instead of waiting for a future.
                fileGate.lock();
                try { for(int frame=0;frame<8;frame++) job.advanceOnGameThread(); check(captured.get()==0,"Capture ran before baseline preparation"); }
                finally { fileGate.unlock(); }
                int slices=0,maxChunks=0;
                long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(15);
                while(job.poll()==null) {
                    int before=captured.get(); job.advanceOnGameThread(); int count=captured.get()-before;
                    maxChunks=Math.max(maxChunks,count); slices++;
                    GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES,null);
                    if(System.nanoTime()>deadline) throw new AssertionError("Cooperative capture failed to converge");
                    Thread.sleep(1);
                }
                check(job.poll().error()==null,"Capture failed: "+job.poll().error());
                check(captured.get()>=362,"Item transfer was missed");
                check(ByteBuffer.wrap(Files.readAllBytes(root.resolve("0.bin"))).getInt()==0 && finalPlayer.get()==1,"Transfer duplicated or lost the item");
                for(int stage=0;stage<stages.length;stage++) check(stages[stage]==(stage==3 ? 0:1),"Save stage repeated/omitted: "+stage);
                check(references.get()==0,"File references retained after completion");
                check(job.diagnostics().contains("captureStatsV1=") && job.diagnostics().contains("recapturedChunks=1"),"Capture slices absent from diagnostics");
                var abandoned=runtime.begin(provider,context); ended.set(true);
                deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);
                while(abandoned.completed()==null) {
                    abandoned.advanceOnGameThread();
                    GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES,null);
                    if(System.nanoTime()>deadline) throw new AssertionError("Aborted capture retained ownership"); Thread.sleep(1);
                }
                check(abandoned.poll().error()!=null && references.get()==0,"World exit was a successful save or leaked file ownership");
                verifyPreparedProgress(io, root, signals, references, fileGate);
                verifyFileConflicts(io, access, root, references);
                System.out.println("PASS: 361 chunks across frames, blocked I/O yields, item-transfer recapture, file conflicts/budgets, world exit; max chunks/call="+maxChunks);
            } finally { signals.unregister(); }
        } finally { try(var files=Files.walk(root)) { for(Path file:files.sorted(Comparator.reverseOrder()).toList()) Files.delete(file); } }
    }
    private static void verifyPreparedProgress(CooperativeChunkWrites io, Path root, SaveSignals signals,
            AtomicInteger references, ReentrantLock fileGate) throws Exception {
        var context = new SaveProvider.Context("throughput", "process", "world", root, Thread.currentThread(), CooperativeCaptureTest.class.getClassLoader());
        Object cell = new Object(), player = new Object(), transferred = new Object();
        var chunks = new ArrayList<Chunk>();
        for (int i = 0; i < 32; i++) chunks.add(new Chunk(i));
        var ended = new AtomicBoolean();
        var ready = new AtomicBoolean(false);
        var captured = new AtomicInteger();
        int[] stages = new int[SaveStageFilter.COUNT];
        var world = new FrameSavePlan.World() {
            public Object currentCell() { return ended.get() ? null : cell; }
            public Object[] currentPlayers() { return new Object[]{player}; }
            public List<WorldChunkCapture.Chunk> chunks(Object expected) {
                return chunks.stream().map(c -> new WorldChunkCapture.Chunk(c,c.x,0,c.load)).toList();
            }
            public boolean same(WorldChunkCapture.Chunk c) {
                return chunks.get(c.x()) == c.object() && ((Chunk)c.object()).load == c.load();
            }
            public boolean dirty(WorldChunkCapture.Chunk c) { return false; }
            public MembershipSnapshot membership(WorldChunkCapture.Chunk c, long budget) throws Exception {
                var value = new MembershipSnapshot(budget); value.list(() -> ((Chunk)c.object()).items); return value;
            }
        };
        var completion = signals.begin(context, false);
        completion.cooperative = io.begin(context, 1024*1024, completion::fail);
        var saving = new FrameSavePlan.Saving() {
            public void stage(int stage) {
                stages[stage]++;
                if (stage == SaveStageFilter.CELL) chunks.getFirst().items.add(transferred);
            }
            public void chunk(Object value) throws Exception {
                Chunk chunk = (Chunk)value;
                io.write(chunk.x, 0, ByteBuffer.allocate(4).putInt(chunk.items.size())); captured.incrementAndGet();
            }
            public void finish(List<WorldChunkCapture.Chunk> current) throws Exception {
                check(current.size() == 32 && sameFirst(current), "Reused chunk escaped final identity checks");
                check(ByteBuffer.wrap(Files.readAllBytes(root.resolve("0.bin"))).getInt() == 1,
                    "Metadata callback transfer was not reconciled before final capture");
                stages[SaveStageFilter.VEHICLES]++;
            }
            private boolean sameFirst(List<WorldChunkCapture.Chunk> current) { return current.getFirst().load() == chunks.getFirst().load; }
        };
        var cellHeld = new AtomicBoolean(); var finalHeld = new AtomicBoolean();
        var readiness = new FrameSavePlan.Ready() {
            public boolean get() { return ready.get(); }
            public int blockers(int stage) {
                if (!ready.get()) return CaptureReadiness.CHUNK_SAVING | CaptureReadiness.QUEUED_CHUNKS;
                if (stage == SaveStageFilter.CELL && cellHeld.compareAndSet(false, true))
                    return CaptureReadiness.NATIVE_SAVING;
                if (stage == SaveStageFilter.VEHICLES && finalHeld.compareAndSet(false, true))
                    return CaptureReadiness.DATABASE_UNAVAILABLE;
                return 0;
            }
        };
        var plan = new FrameSavePlan(context, world, saving, readiness, io, completion.cooperative, completion,
            new CaptureTimings(), 1024*1024);
        boolean completed = false;
        try {
            check(!plan.advance(1), "A spent budget failed to yield");
            check(stages[0] == 1 && stages[1] == 0, "Metadata continued after its budget expired");
            fileGate.lock();
            try {
                check(!plan.advance(TimeUnit.SECONDS.toNanos(30)), "Unready worker allowed capture");
                check(stages[1] == 1 && stages[2] == 1 && captured.get() == 0, "Light metadata did not share its available budget");
                check(references.get() == 32, "Readiness wait did not prefetch the bounded ticket window");
                check(!plan.advance(TimeUnit.SECONDS.toNanos(30)) && references.get() == 32 && captured.get() == 0,
                    "Repeated readiness wait grew the window or serialized a chunk");
                ready.set(true);
                check(!plan.advance(TimeUnit.SECONDS.toNanos(30)) && captured.get() == 0,
                    "Blocked baseline preparation froze or admitted capture");
                check(references.get() == 32, "Preparation did not fill the bounded ticket window");
            } finally { fileGate.unlock(); }
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (true) {
                synchronized (completion.cooperative) {
                    if (completion.cooperative.pending.size() == 32
                            && completion.cooperative.pending.stream().allMatch(ticket -> ticket.ready)) break;
                }
                if (System.nanoTime() > deadline) throw new AssertionError("Prepared throughput fixture timed out");
                Thread.sleep(1);
            }
            // Reuse one object after its ticket is prepared. Other ready chunks must still make progress.
            chunks.getFirst().load++;
            completed = plan.advance(TimeUnit.SECONDS.toNanos(30));
            check(captured.get() >= 31, "Prepared chunks retained the former four-chunk ceiling or blocked behind a replaced ticket");
            deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (!completed) {
                completed = plan.advance(TimeUnit.SECONDS.toNanos(30));
                if (System.nanoTime() > deadline) throw new AssertionError("Prepared capture did not converge");
                if (!completed) Thread.sleep(1);
            }
            check(plan.diagnostics().contains("captureYieldStatsV1=") && plan.diagnostics().contains("recapturedChunks=1"),
                "Yield attribution or callback recapture diagnostics were lost");
            long[] stageWaits = statistic(plan.diagnostics(), "readinessStageStatsV1");
            long[] reasonWaits = statistic(plan.diagnostics(), "readinessReasonStatsV1");
            check(stageWaits[0] == 2 && stageWaits[2] == 1 && stageWaits[4] == 1,
                "Readiness waits were not attributed to chunks, cell and final capture: " + Arrays.toString(stageWaits));
            check(reasonWaits[0] == 1 && reasonWaits[4] == 2 && reasonWaits[6] == 2 && reasonWaits[10] == 1,
                "Overlapping readiness reasons were not counted independently");
            check(statistic(plan.diagnostics(), "readinessPrefetchV1")[0] == 32,
                "Readiness prefetch count was lost or included serialized outputs");
            for (int stage = 0; stage < stages.length; stage++)
                check(stages[stage] == (stage == 3 ? 0 : 1), "Combined stage repeated or omitted: " + stage);
        } finally {
            if (!completed) plan.abort(new java.io.IOException("Throughput fixture ended before capture"));
            GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES, null);
            boolean committed = completed;
            var close = new FutureTask<Void>(() -> { try (plan) { if (committed) plan.commit(); } return null; });
            Thread.ofVirtual().start(close); close.get(5, TimeUnit.SECONDS);
        }
        check(references.get() == 0, "Replaced prepared ticket retained file ownership");
        var prefetched = signals.begin(context, false);
        prefetched.cooperative = io.begin(context, 1024*1024, prefetched::fail);
        var noSerialization = new FrameSavePlan.Saving() {
            public void stage(int stage) { check(stage < 3, "Unready capture advanced a guarded stage"); }
            public void chunk(Object value) { throw new AssertionError("Unready capture serialized a chunk"); }
            public void finish(List<WorldChunkCapture.Chunk> current) { throw new AssertionError("Unready capture finished"); }
        };
        var prefetchExit = new FrameSavePlan(context, world, noSerialization, () -> false, io,
            prefetched.cooperative, prefetched, new CaptureTimings(), 1024*1024);
        try {
            check(!prefetchExit.advance(TimeUnit.SECONDS.toNanos(30)) && references.get() == 32,
                "Unready capture did not retain exactly its prepared tickets");
            ended.set(true);
            try { prefetchExit.advance(TimeUnit.SECONDS.toNanos(30)); throw new AssertionError("Prefetch ignored world exit"); }
            catch (java.io.IOException expected) { prefetchExit.abort(expected); }
        } finally {
            prefetchExit.abort(new java.io.IOException("Prefetch-exit fixture ended"));
            GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES, null);
            var close = new FutureTask<Void>(() -> { prefetchExit.close(); return null; });
            Thread.ofVirtual().start(close); close.get(5, TimeUnit.SECONDS); ended.set(false);
        }
        check(references.get() == 0, "World exit leaked unsubmitted readiness-prefetch tickets");
        var exiting = signals.begin(context, false);
        exiting.cooperative = io.begin(context, 1024*1024, exiting::fail);
        var exitsDuringMetadata = new FrameSavePlan.Saving() {
            public void stage(int stage) {
                check(stage == 0, "A later metadata stage ran after its callback changed the world"); ended.set(true);
            }
            public void chunk(Object value) { throw new AssertionError("Changed world captured chunks"); }
            public void finish(List<WorldChunkCapture.Chunk> current) { throw new AssertionError("Changed world completed"); }
        };
        var abandoned = new FrameSavePlan(context, world, exitsDuringMetadata, () -> true, io,
            exiting.cooperative, exiting, new CaptureTimings(), 1024*1024);
        try {
            try { abandoned.advance(TimeUnit.SECONDS.toNanos(30)); throw new AssertionError("Callback world exit was ignored"); }
            catch (java.io.IOException expected) { abandoned.abort(expected); }
        } finally {
            abandoned.abort(new java.io.IOException("World-exit fixture ended"));
            GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES, null);
            var close = new FutureTask<Void>(() -> { abandoned.close(); return null; });
            Thread.ofVirtual().start(close); close.get(5, TimeUnit.SECONDS);
        }
        System.out.println("PASS: spent-budget yield, readiness reasons/stages, guarded 32-ticket prefetch and world-exit cleanup, 31+ ready chunks, reused identity and callback recapture");
    }
    private static long[] statistic(String diagnostics, String name) {
        String prefix = name + "=";
        for (String field : diagnostics.split("; ")) if (field.startsWith(prefix))
            return Arrays.stream(field.substring(prefix.length()).split(",")).mapToLong(Long::parseLong).toArray();
        throw new AssertionError("Missing diagnostic: " + name);
    }
    private static void indexedCollectionsKeepTransferChecks() throws Exception {
        verifyIndexedCollection(new IndexedList<>());
    }
    public static void verifyIndexedCollection(List<Object> list) throws Exception {
        Object first = new Object(), second = new Object();
        list.add(first); list.add(null); list.add(second);
        var reference = new AtomicReference<>(list);
        var original = new MembershipSnapshot(1024);
        Object[] captured = original.list(reference::get);
        check(captured.length == 3 && captured[0] == first && captured[1] == null && captured[2] == second,
            "Indexed collection snapshot changed order, identity or null entries");
        check(original.unchanged(), "Indexed collection rejected without a transfer");
        list.set(0, second);
        check(captured[0] == first, "Collection snapshot retained a live backing array");
        check(!original.unchanged(), "Same-size item replacement was missed");
        list.set(0, first);
        check(original.unchanged(), "Restored membership did not match");
        var resized = new MembershipSnapshot(1024); resized.list(reference::get);
        list.add(new Object());
        check(!resized.unchanged(), "Indexed collection size change was missed");
        var replaced = new MembershipSnapshot(1024); replaced.list(reference::get);
        reference.set(new IndexedList<>());
        check(!replaced.unchanged(), "Collection replacement was missed");
    }
    private static void verifyFileConflicts(CooperativeChunkWrites io, OwnedChunkWrites.Access access,
            Path root, AtomicInteger references) throws Exception {
        var context = new SaveProvider.Context("files", "process", "world", root, Thread.currentThread(), CooperativeCaptureTest.class.getClassLoader());
        AtomicReference<Throwable> errors = new AtomicReference<>();
        var batch = io.begin(context, 64, errors::set);
        var ticket = batch.prepare(0,0); awaitReady(ticket);
        access.synchronous(0,0,ByteBuffer.allocate(4).putInt(42)); // A later ordinary write wins.
        io.bind(ticket);
        try { io.write(0,0,ByteBuffer.allocate(4).putInt(99)); } finally { io.unbind(ticket); batch.seal(); }
        awaitBatch(batch);
        check(ticket.conflict && errors.get()==null && references.get()==0,"Stale private bytes were not rejected cleanly");
        check(ByteBuffer.wrap(Files.readAllBytes(root.resolve("0.bin"))).getInt()==42,"Private write overwrote the newer normal save");
        var limited=io.begin(context,1,errors::set);
        var rejected=limited.prepare(0,0); awaitReady(rejected); io.bind(rejected);
        try {
            io.write(0,0,ByteBuffer.allocate(4).putInt(100));
            throw new AssertionError("Over-budget write accepted");
        } catch(java.io.IOException expected) { }
        finally { io.unbind(rejected); limited.seal(); }
        try { awaitBatch(limited); throw new AssertionError("Rejected write reported success"); }
        catch(ExecutionException expected) { check(expected.getCause() instanceof java.io.IOException,"Lost write failure"); }
        check(references.get()==0 && rejected.finished,"Budget failure stranded a prepared channel or lock reference");
    }
    private static void awaitReady(CooperativeChunkWrites.Ticket ticket) throws Exception {
        long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);
        while(!ticket.ready && !ticket.finished) {
            if(System.nanoTime()>deadline) throw new AssertionError("File baseline preparation did not finish"); Thread.sleep(1);
        }
        check(ticket.ready && ticket.failure==null,"File preparation failed");
    }
    private static void awaitBatch(CooperativeChunkWrites.Batch batch) throws Exception {
        var task=new FutureTask<Void>(() -> { batch.await(); return null; });
        Thread.ofVirtual().start(task); task.get(5,TimeUnit.SECONDS);
    }
    private static void check(boolean value,String message) { if(!value) throw new AssertionError(message); }
}
