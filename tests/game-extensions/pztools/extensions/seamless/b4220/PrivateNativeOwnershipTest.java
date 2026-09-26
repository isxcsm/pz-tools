package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import java.lang.invoke.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/** Included in the existing private-entry harness, not an additional CI job or benchmark. */
final class PrivateNativeOwnershipTest {
    static void run(Path classes) throws Throwable {
        try (Fixture f = new Fixture(classes)) {
            f.gate("releaseNative", 1); f.gate("preNative", 1);
            Future<SaveSignals.Batch> capture = f.capture();
            f.await("preEntered");
            // Acquiring saveLock before the observed native entry would deadlock this prior-phase call.
            f.other.submit(() -> { f.population.getMethod("processPendingSaveCells").invoke(f.pop); return null; }).get(10,TimeUnit.SECONDS);
            f.release("preNative");
            SaveSignals.Batch batch = capture.get(10,TimeUnit.SECONDS); f.await("nativeEntered");
            check(f.game.submit(() -> 42).get(10,TimeUnit.SECONDS) == 42, "Private save blocked the next game task");
            Future<?> complete = f.complete(batch);
            check(!complete.isDone() && f.type.getField("writes").getInt(f.owner)==0, "Native write acknowledged early");
            // The original public save must use its original lock; it must not replace the first native input.
            Future<?> vanilla = f.game.submit(() -> { f.window.getMethod("save",boolean.class).invoke(null,true); return null; });
            f.release("releaseNative"); complete.get(10,TimeUnit.SECONDS); vanilla.get(10,TimeUnit.SECONDS);
            check(f.population.getField("captures").getInt(f.pop)==2
                && f.population.getField("writesAtLastCapture").getInt(f.pop)==1, "Normal save overtook the native snapshot");
        }
        try (Fixture f = new Fixture(classes)) {
            f.gate("releaseNative", 1);
            SaveSignals.Batch batch=f.capture().get(10,TimeUnit.SECONDS); f.await("nativeEntered");
            Future<?> stopping=f.other.submit(() -> { f.type.getMethod("stop").invoke(f.owner); return null; });
            Future<?> complete=f.complete(batch);
            f.release("releaseNative"); stopping.get(10,TimeUnit.SECONDS); complete.get(10,TimeUnit.SECONDS);
            check(f.type.getField("writes").getInt(f.owner)==1, "Unmodified stop abandoned the active native write");
        }
        try (Fixture f = new Fixture(classes)) {
            f.type.getField("failOnce").setBoolean(f.owner,true);
            SaveSignals.Batch batch=f.capture().get(10,TimeUnit.SECONDS);
            failure(f.complete(batch));
            check(f.type.getField("writes").getInt(f.owner)==1, "Native retry was abandoned or error converted to success");
        }
        try (Fixture f = new Fixture(classes)) {
            f.gate("releaseNative", 1);
            SaveSignals.Batch batch=f.capture().get(10,TimeUnit.SECONDS); f.await("nativeEntered");
            f.currentContext.worldValid().set(false);
            Future<?> complete=f.complete(batch);
            check(!complete.isDone(), "World invalidation released native work before it settled");
            f.release("releaseNative"); failure(complete);
        }
        try (Fixture f = new Fixture(classes)) {
            f.type.getField("exitWithoutAck").setBoolean(f.owner,true);
            SaveSignals.Batch batch=f.capture().get(10,TimeUnit.SECONDS);
            failure(f.complete(batch));
            check(f.type.getField("writes").getInt(f.owner)==0, "Unacknowledged worker termination reported a write");
        }
        try (Fixture f = new Fixture(classes)) {
            f.type.getMethod("stop").invoke(f.owner);
            SaveSignals.Batch batch=f.capture().get(10,TimeUnit.SECONDS); f.complete(batch).get(10,TimeUnit.SECONDS);
            check(f.type.getField("writes").getInt(f.owner)==1, "No worker must preserve original synchronous native saving");
        }
    }
    private static void failure(Future<?> result) throws Exception {
        try { result.get(10,TimeUnit.SECONDS); throw new AssertionError("Save failure became success"); }
        catch(ExecutionException expected) {
            if(!(expected.getCause() instanceof java.io.IOException)) throw expected;
        }
    }
    private static void check(boolean condition,String message){if(!condition)throw new AssertionError(message);}
    private static final class Fixture implements AutoCloseable {
        final URLClassLoader loader;
        final Class<?> type, population, window;
        final Object owner, pop;
        final Path root;
        final SaveSignals signals = new SaveSignals();
        final OwnedNativeSave nativeSave;
        final OwnedChunkWrites writes;
        final CaptureTimings timings = new CaptureTimings();
        volatile SaveProvider.Context currentContext;
        final PrivateSaveGraph entry;
        final ExecutorService game=Executors.newSingleThreadExecutor(), other=Executors.newCachedThreadPool();
        Fixture(Path classes) throws Throwable {
            root=Files.createTempDirectory("pztools-private-native-");
            loader=new URLClassLoader(new URL[]{classes.toUri().toURL()}, PrivateNativeOwnershipTest.class.getClassLoader()){
                protected Class<?> findClass(String name) throws ClassNotFoundException {
                    if(!name.equals("zombie.MapCollisionData$MCDThread")) return super.findClass(name);
                    try(var in=getResourceAsStream(name.replace('.','/')+".class")){
                        byte[] bytes=NativeSaveObservation.transform(in.readAllBytes(),this);
                        return defineClass(name,bytes,0,bytes.length);
                    }catch(Exception failure){throw new ClassNotFoundException(name,failure);}
                }
            };
            type=loader.loadClass("zombie.MapCollisionData"); owner=type.getField("instance").get(null);
            population=loader.loadClass("zombie.popman.ZombiePopulationManager"); pop=population.getField("instance").get(null);
            window=loader.loadClass("zombie.GameWindow");
            loader.loadClass("zombie.ChunkMapFilenames").getField("root").set(null,root.toFile());
            nativeSave=new OwnedNativeSave(loader); nativeSave.register(); signals.register();
            writes=new OwnedChunkWrites(new GameChunkAccess(loader));
            var sources=new HashMap<String,byte[]>();
            for(var ref:PrivateSaveGraph.SOURCES) sources.put(ref.owner(),Files.readAllBytes(classes.resolve(ref.owner()+".class")));
            var sink=MethodHandles.lookup().findVirtual(OwnedChunkWrites.class,"write",MethodType.methodType(void.class,int.class,int.class,ByteBuffer.class)).bindTo(writes);
            entry=PrivateSaveGraph.create(loader,sources,sink,timings,nativeSave);
        }
        Future<SaveSignals.Batch> capture(){
            return game.submit(() -> {
                var context=new SaveProvider.Context("native","session","world",root,Thread.currentThread(),loader);
                currentContext=context; var batch=signals.begin(context,false); timings.start();
                batch.nativeWork=nativeSave.begin(context,batch::fail); batch.chunks=writes.begin(context,65536,batch::fail);
                try { entry.saveForBackup(); } catch(Throwable failure){batch.fail(failure);}
                finally {batch.detail=timings.finish(); batch.arm();}
                GameHooks.enter(SaveSignals.VEHICLES); GameHooks.exit(SaveSignals.VEHICLES,null);
                return batch;
            });
        }
        Future<?> complete(SaveSignals.Batch batch){return other.submit(() -> {try(batch){batch.commit();}return null;});}
        void gate(String name,int count)throws Exception{type.getField(name).set(owner,new CountDownLatch(count));}
        void release(String name)throws Exception{((CountDownLatch)type.getField(name).get(owner)).countDown();}
        void await(String name)throws Exception{check(((CountDownLatch)type.getField(name).get(owner)).await(10,TimeUnit.SECONDS),"Missing fixture signal: "+name);}
        public void close()throws Exception{
            release("preNative"); release("releaseNative");
            game.shutdown(); other.shutdown();
            check(game.awaitTermination(10,TimeUnit.SECONDS),"Private game task did not settle");
            check(other.awaitTermination(10,TimeUnit.SECONDS),"Native completion did not settle");
            type.getMethod("stop").invoke(owner);
            writes.close(); nativeSave.unregister(); signals.unregister(); loader.close();
            try(var files=Files.walk(root)){for(var file:files.sorted(Comparator.reverseOrder()).toList())Files.delete(file);}
        }
    }
}