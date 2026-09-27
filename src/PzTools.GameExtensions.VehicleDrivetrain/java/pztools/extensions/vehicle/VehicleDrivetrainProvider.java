package pztools.extensions.vehicle;

import java.lang.instrument.*;
import java.security.ProtectionDomain;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.*;
import pztools.extensions.api.*;

/** Explicitly activated local-SP module. Installation instruments only an inert stable hook. */
public final class VehicleDrivetrainProvider implements ContinuousProvider {
    private Instrumentation instrumentation;
    private Class<?> target;
    private ClassFileTransformer transformer;
    private VehicleAccess access;
    private final Object transformationGate=new Object();
    private final AtomicReference<Throwable> transformationFailure=new AtomicReference<>();
    private final AtomicReference<PreflightCapture> preflightCapture=new AtomicReference<>();
    private record PreflightPass(byte[] input,byte[] expectedFingerprint) { }
    private static final class PreflightCapture {
        final Map<Thread,PreflightPass> passes=new ConcurrentHashMap<>();
        final AtomicReference<byte[]> input=new AtomicReference<>();
        final AtomicReference<Throwable> failure=new AtomicReference<>();
    }
    private volatile boolean retired;
    private boolean initialized,registered,disposed;
    private VehicleHooks.Retirement retirement;
    private volatile VehicleControl control;

    @Override public String id() { return "pztools.vehicle-drivetrain"; }
    /** Bounded offline input for the separate-JVM verifier, not a live compatibility decision. */
    public static byte[] verifyResources(ClassLoader loader) throws Exception {
        try(var in=loader.getResourceAsStream(VehicleBytecode.TARGET+".class")) {
            if(in==null) throw new IllegalArgumentException("missing-game-resource:"+VehicleBytecode.TARGET);
            int limit=4*1024*1024;
            byte[] bytes=in.readNBytes(limit+1);
            if(bytes.length>limit) throw new IllegalArgumentException("oversized-game-resource:"+VehicleBytecode.TARGET);
            return bytes;
        }
    }
    /** Resolve private field types and methods without reading or changing a game instance. */
    public static void verifyAccess(ClassLoader loader) throws ReflectiveOperationException { new VehicleAccess(loader); }
    @Override public Support preflight(Instrumentation instrumentation,ClassLoader loader,PreflightSource activeSource) throws Exception {
        if(instrumentation==null || Runtime.version().feature()!=25 || !instrumentation.isRetransformClassesSupported())
            return new Support(false,"unsupported-runtime");
        if(Class.forName(VehicleHooks.class.getName(),false,loader)!=VehicleHooks.class) return new Support(false,"unsupported-hook-loader");
        // Reject missing/type-changed handles before asking the healthy active generation to retransform.
        new VehicleAccess(loader);
        Class<?> candidateTarget=Class.forName(VehicleBytecode.TARGET.replace('/','.'),false,loader);
        if(!instrumentation.isModifiableClass(candidateTarget)) return new Support(false,"unmodifiable-controller");
        byte[] live=activeSource.capture(candidateTarget);
        if(live==null) live=captureUnownedInput(instrumentation,loader,candidateTarget);
        try { VehicleBytecode.transform(live,loader); }
        catch(IllegalArgumentException rejected) { return new Support(false,"controller-contract-changed"); }
        return new Support(true,null);
    }
    private static byte[] captureUnownedInput(Instrumentation instrumentation,ClassLoader loader,Class<?> target) throws Exception {
        var captured=new AtomicReference<byte[]>();
        ClassFileTransformer observer=new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner,String name,Class<?> type,ProtectionDomain domain,byte[] bytes) {
                if(owner==loader && type==target) captured.set(bytes.clone());
                return null; // Never install or erase any transformer's output.
            }
        };
        instrumentation.addTransformer(observer,true);
        try {
            instrumentation.retransformClasses(target);
            byte[] bytes=captured.get();
            if(bytes==null) throw new IllegalStateException("preflight-controller-not-observed");
            return bytes;
        } finally {
            if(!instrumentation.removeTransformer(observer)) throw new IllegalStateException("preflight-observer-retirement-failed");
        }
    }
    @Override public byte[] capturePreflightInput(Class<?> requestedTarget) throws Exception {
        if(requestedTarget!=target || !initialized || retired || disposed) return null;
        var captured=new PreflightCapture();
        if(!preflightCapture.compareAndSet(null,captured)) throw new IllegalStateException("preflight-already-running");
        ClassLoader loader=requestedTarget.getClassLoader();
        ClassFileTransformer tail=new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner,String name,Class<?> type,ProtectionDomain domain,byte[] bytes) {
                if(owner!=loader || type!=requestedTarget) return null;
                try {
                    // Pair within this exact transform pass, rather than accidentally accepting another concurrent pass.
                    var pass=captured.passes.remove(Thread.currentThread());
                    if(pass==null) throw new IllegalStateException("preflight-active-output-not-observed");
                    if(!Arrays.equals(pass.expectedFingerprint(),VehicleBytecode.fingerprint(bytes,loader)))
                        throw new IllegalStateException("preflight-downstream-controller-changed");
                    captured.input.set(pass.input());
                } catch(Throwable failure) { captured.failure.compareAndSet(null,failure); }
                return null; // Observe the existing chain; do not erase downstream output or alter old ownership.
            }
        };
        boolean added=false;
        try {
            // Existing later Java transformers now precede this observer. Future registration/JNI remains outside the snapshot.
            instrumentation.addTransformer(tail,true); added=true;
            instrumentation.retransformClasses(requestedTarget);
            if(captured.failure.get()!=null) throw new IllegalStateException("preflight-chain-output-changed",captured.failure.get());
            byte[] bytes=captured.input.get();
            if(bytes==null || transformationFailure.get()!=null || retired)
                throw new IllegalStateException("preflight-active-controller-unavailable");
            return bytes;
        } finally {
            preflightCapture.compareAndSet(captured,null);
            try { if(added && !instrumentation.removeTransformer(tail)) throw new IllegalStateException("preflight-observer-retirement-failed"); }
            finally { captured.passes.clear(); }
        }
    }
    @Override public Support initialize(Instrumentation instrumentation,ClassLoader loader) throws Exception {
        if(retired || disposed) return new Support(false,"module-retired");
        if(initialized) return new Support(transformationFailure.get()==null,"game-code-changed");
        if(instrumentation==null || Runtime.version().feature()!=25 || !instrumentation.isRetransformClassesSupported())
            return new Support(false,"unsupported-runtime");
        if(Class.forName(VehicleHooks.class.getName(),false,loader)!=VehicleHooks.class) return new Support(false,"unsupported-hook-loader");
        access=new VehicleAccess(loader);
        target=Class.forName(VehicleBytecode.TARGET.replace('/','.'),false,loader);
        if(!instrumentation.isModifiableClass(target)) return new Support(false,"unmodifiable-controller");
        AtomicBoolean observed=new AtomicBoolean();
        transformer=new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner,String name,Class<?> type,ProtectionDomain domain,byte[] bytes) {
                synchronized(transformationGate) {
                    if(retired || owner!=loader || type!=target) return null;
                    try {
                        // Every retransformation validates and plans against this exact chain input.
                        byte[] transformed=VehicleBytecode.transform(bytes,loader);
                        var captured=preflightCapture.get();
                        if(captured!=null) try {
                            if(captured.passes.size()>=16) throw new IllegalStateException("preflight-concurrent-transform-limit");
                            captured.passes.put(Thread.currentThread(),new PreflightPass(bytes.clone(),VehicleBytecode.fingerprint(transformed,loader)));
                        } catch(Throwable failure) { captured.failure.compareAndSet(null,failure); }
                        observed.set(true); return transformed;
                    } catch(Throwable failure) { transformationFailure.compareAndSet(null,failure); deactivate(); return null; }
                }
            }
        };
        this.instrumentation=instrumentation;
        try {
            instrumentation.addTransformer(transformer,true); instrumentation.retransformClasses(target);
            if(!observed.get() || transformationFailure.get()!=null) throw new IllegalStateException("controller-transform-rejected",transformationFailure.get());
            initialized=true; return new Support(true,null);
        } catch(Throwable failure) {
            synchronized(transformationGate) { retired=true; }
            instrumentation.removeTransformer(transformer);
            instrumentation.retransformClasses(target);
            return new Support(false,"unsupported-controller-layout");
        }
    }
    @Override public void validateConfig(Map<String,String> config) { new VehicleControl.Settings(config); }
    @Override public boolean readyToActivate(Context context,Map<String,String> config) throws Exception {
        try { return access!=null && access.ready(context); }
        catch(Throwable failure) { throw checked(failure); }
    }
    @Override public synchronized void activate(Context context,Map<String,String> config) throws Exception {
        context.requireGameThread();
        if(!initialized || retired || transformationFailure.get()!=null) throw new IllegalStateException("adapter-not-ready");
        if(registered) throw new IllegalStateException("already-active");
        var settings=new VehicleControl.Settings(config);
        if(!readyToActivate(context,config)) throw new IllegalStateException("safe-boundary-required");
        var next=new VehicleControl(access,context,settings);
        if(!context.worldValid().get()) throw new IllegalStateException("world-ended");
        VehicleHooks.register(this,next); control=next; registered=true;
        if(!context.worldValid().get()) { deactivate(); throw new IllegalStateException("world-ended"); }
    }
    @Override public synchronized void updateConfig(Map<String,String> config) throws Exception {
        var current=control;
        if(!registered || current==null) throw new IllegalStateException("not-active");
        current.context.requireGameThread();
        var settings=new VehicleControl.Settings(config);
        if(!readyToActivate(current.context,config)) throw new IllegalStateException("safe-boundary-required");
        current.reconfigure(settings);
    }
    @Override public String diagnostics() { var current=control; return current==null?"":current.diagnostics(); }
    @Override public String failureReason() { return transformationFailure.get()==null?null:"controller-contract-changed"; }
    @Override public synchronized void deactivate() {
        if(registered) { registered=false; retirement=VehicleHooks.unregister(this); }
    }
    @Override public void close() throws Exception {
        deactivate();
        VehicleHooks.Retirement wait;
        synchronized(this) { if(disposed) return; wait=retirement; }
        if(wait!=null) wait.await(5000);
        synchronized(transformationGate) { retired=true; }
        if(instrumentation!=null && transformer!=null) {
            instrumentation.removeTransformer(transformer); instrumentation.retransformClasses(target);
        }
        synchronized(this) {
            if(control!=null) control.clear(); control=null; access=null; target=null; transformer=null;
            instrumentation=null; initialized=false; disposed=true;
        }
    }
    private static Exception checked(Throwable failure) {
        if(failure instanceof Exception exception) return exception;
        if(failure instanceof Error error) throw error;
        return new IllegalStateException(failure);
    }
}
