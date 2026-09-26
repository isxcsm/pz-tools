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
    private static final class Chunk {
        final int x; final List<Object> items = new ArrayList<>();
        Chunk(int x) { this.x = x; }
    }
    public static void run() throws Exception {
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
                    if(captured.get()>=4 && mutation.compareAndSet(false,true)) {
                        chunks.getFirst().items.clear(); inventory.add(item);
                    }
                    GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES,null);
                    if(System.nanoTime()>deadline) throw new AssertionError("Cooperative capture failed to converge");
                    Thread.sleep(1);
                }
                check(job.poll().error()==null,"Capture failed: "+job.poll().error());
                check(captured.get()>=362 && maxChunks<=4 && slices>40,"Chunks were collapsed into one call or transfer was missed");
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
                verifyFileConflicts(io, access, root, references);
                System.out.println("PASS: 361 chunks across frames, blocked I/O yields, item-transfer recapture, file conflicts/budgets, world exit; max chunks/call="+maxChunks);
            } finally { signals.unregister(); }
        } finally { try(var files=Files.walk(root)) { for(Path file:files.sorted(Comparator.reverseOrder()).toList()) Files.delete(file); } }
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
