import java.lang.classfile.*;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.instrument.*;
import java.net.URLClassLoader;
import java.nio.file.*;
import java.util.concurrent.atomic.*;
import pztools.extensions.vehicle.*;

/** Read-only: loads metadata in a separate JVM, never starts/attaches to a game or invokes vehicle physics. */
public final class VerifyInstalledVehicleBytecode {
    public static void main(String[] args) throws Exception {
        if(args.length!=1) throw new IllegalArgumentException("Expected installed projectzomboid.jar path");
        Path jar=Path.of(args[0]).toAbsolutePath();
        try(var loader=new URLClassLoader(new java.net.URL[]{jar.toUri().toURL()},VerifyInstalledVehicleBytecode.class.getClassLoader())) {
            byte[] original=VehicleDrivetrainProvider.verifyResources(loader);
            byte[] transformed=VehicleBytecode.transform(original,loader);
            var cf=ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
            var errors=cf.verify(transformed);
            if(!errors.isEmpty()) throw new AssertionError(errors.toString());
            VehicleDrivetrainProvider.verifyAccess(loader);
            try { VehicleBytecode.transform(transformed,loader); throw new AssertionError("Duplicate transformation accepted"); }
            catch(IllegalArgumentException expected) { }
            System.out.println("VERIFIED (not executed): pinned vehicle resources, resolved-mode/offroad transform, JVM verification, access contracts and duplicate rejection");
            System.out.println("Controller canonical SHA-256: "+VehicleBytecode.sha256(VehicleBytecode.fingerprint(original,loader)));
            if(PrivateValidationAgent.instrumentation!=null) lifecycle(PrivateValidationAgent.instrumentation,loader,original);
        }
    }

    /** Instruments private definitions in this verifier JVM; never constructs/initializes a game class. */
    private static void lifecycle(Instrumentation instrumentation,ClassLoader loader,byte[] original) throws Exception {
        var cf=ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
        Class<?> target=Class.forName(VehicleBytecode.TARGET.replace('/','.'),false,loader);
        AtomicBoolean conflict=new AtomicBoolean(); AtomicInteger foreignCalls=new AtomicInteger();
        AtomicReference<Throwable> foreignFailure=new AtomicReference<>();
        ClassFileTransformer foreign=new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner,String name,Class<?> type,java.security.ProtectionDomain domain,byte[] bytes) {
                if(owner!=loader || type!=target) return null;
                try {
                    foreignCalls.incrementAndGet();
                    return cf.transformClass(cf.parse(bytes),ClassTransform.transformingMethodBodies(
                        m -> m.methodName().equalsString(conflict.get()?"update":"<init>"),CodeTransform.ofStateful(()->new CodeTransform() {
                            @Override public void atStart(CodeBuilder b) { b.nop(); }
                            @Override public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
                        })));
                } catch(Throwable failure) { foreignFailure.set(failure); return null; }
            }
        };
        instrumentation.addTransformer(foreign,true);
        try {
            for(int generation=0;generation<3;generation++) {
                var provider=new VehicleDrivetrainProvider();
                try {
                    if(!provider.preflight(instrumentation,loader,type->null).supported())
                        throw new AssertionError("Initial read-only preflight rejected");
                    var support=provider.initialize(instrumentation,loader);
                    if(!support.supported()) {
                        var failure=VehicleDrivetrainProvider.class.getDeclaredField("transformationFailure"); failure.setAccessible(true);
                        throw new AssertionError("Offline production admission rejected: "+support,(Throwable)((AtomicReference<?>)failure.get(provider)).get());
                    }
                    AtomicReference<byte[]> observed=new AtomicReference<>();
                    var audit=new ClassFileTransformer() {
                        @Override public byte[] transform(ClassLoader owner,String name,Class<?> type,java.security.ProtectionDomain domain,byte[] bytes) {
                            if(owner==loader && type==target) observed.set(bytes.clone()); return null;
                        }
                    };
                    instrumentation.addTransformer(audit,true);
                    try {
                        instrumentation.retransformClasses(target);
                        if(hooks(cf,observed.get(),"tryControl")!=2) throw new AssertionError("Installed generation must contain propulsion and steering dispatchers");
                        if(hooks(cf,observed.get(),"observeNative")!=2) throw new AssertionError("Installed generation does not observe both native callsites");
                        if(provider.failureReason()!=null) throw new AssertionError("Unexpected transformer failure");
                        // The old provider refreshes its own pre-hook input; a candidate must not mistake installed hooks for foreign code.
                        try(var candidate=new VehicleDrivetrainProvider()) {
                            if(!candidate.preflight(instrumentation,loader,provider::capturePreflightInput).supported())
                                throw new AssertionError("Replacement preflight rejected the old generation's own hooks");
                            var rejected=candidate.preflight(instrumentation,loader,type-> {
                                byte[] bytes=provider.capturePreflightInput(type);
                                return cf.transformClass(cf.parse(bytes),ClassTransform.transformingMethodBodies(
                                    m->m.methodName().equalsString("update"),CodeTransform.ofStateful(()->new CodeTransform() {
                                        @Override public void atStart(CodeBuilder b) { b.nop(); }
                                        @Override public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
                                    })));
                            });
                            if(rejected.supported() || !"controller-contract-changed".equals(rejected.reason()))
                                throw new AssertionError("Candidate live-code incompatibility escaped preflight");
                        }
                        if(provider.failureReason()!=null || hooks(cf,observed.get(),"tryControl")!=2
                                || hooks(cf,observed.get(),"observeNative")!=2)
                            throw new AssertionError("Rejected candidate damaged the old inert generation");
                        rejectLaterTransformer(instrumentation,loader,target,provider,cf);
                        provider.deactivate(); provider.close();
                        if(hooks(cf,observed.get(),null)!=0) throw new AssertionError("Retired vehicle hooks remained installed");
                        if(!java.util.Arrays.equals(VehicleBytecode.fingerprint(original,loader),VehicleBytecode.fingerprint(observed.get(),loader)))
                            throw new AssertionError("Retirement changed original controller methods");
                        long before=nopsInConstructors(cf,original), after=nopsInConstructors(cf,observed.get());
                        if(after<=before) throw new AssertionError("Retirement removed the unrelated constructor transformer");
                    } finally { instrumentation.removeTransformer(audit); }
                } finally { provider.close(); }
            }
            var provider=new VehicleDrivetrainProvider();
            try {
                if(!provider.initialize(instrumentation,loader).supported()) throw new AssertionError("Conflict fixture admission rejected early");
                conflict.set(true); instrumentation.retransformClasses(target);
                if(provider.failureReason()==null) throw new AssertionError("Live conflicting update was not reported");
            } finally { provider.close(); }
            if(foreignFailure.get()!=null) throw new AssertionError("Foreign transformer failed",foreignFailure.get());
            if(foreignCalls.get()<12) throw new AssertionError("External transformer was not retained across retirement");
            System.out.println("VERIFIED (offline JVM, no game invocation): three inert install/retransform/retire cycles, non-retiring preflight including later-transform rejection, foreign-transform preservation, live-conflict rejection");
        } finally {
            instrumentation.removeTransformer(foreign); instrumentation.retransformClasses(target);
        }
    }
    private static void rejectLaterTransformer(Instrumentation instrumentation,ClassLoader loader,Class<?> target,
            VehicleDrivetrainProvider active,ClassFile cf) throws Exception {
        AtomicReference<byte[]> laterOutput=new AtomicReference<>();
        AtomicReference<Throwable> laterFailure=new AtomicReference<>();
        ClassFileTransformer later=new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner,String name,Class<?> type,java.security.ProtectionDomain domain,byte[] bytes) {
                if(owner!=loader || type!=target) return null;
                try {
                    byte[] result=cf.transformClass(cf.parse(bytes),ClassTransform.transformingMethodBodies(
                        m->m.methodName().equalsString("update"),CodeTransform.ofStateful(()->new CodeTransform() {
                            @Override public void atStart(CodeBuilder b) { b.nop(); }
                            @Override public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
                        })));
                    laterOutput.set(result); return result;
                } catch(Throwable failure) { laterFailure.set(failure); return null; }
            }
        };
        instrumentation.addTransformer(later,true);
        try(var candidate=new VehicleDrivetrainProvider()) {
            boolean rejected=false;
            try { candidate.preflight(instrumentation,loader,active::capturePreflightInput); }
            catch(IllegalStateException expected) { rejected="preflight-chain-output-changed".equals(expected.getMessage()); }
            if(!rejected) throw new AssertionError("A transformer registered after the active provider escaped preflight");
            if(laterFailure.get()!=null) throw new AssertionError("Later transformer fixture failed",laterFailure.get());
            if(active.failureReason()!=null || hooks(cf,laterOutput.get(),"tryControl")!=2
                    || hooks(cf,laterOutput.get(),"observeNative")!=2)
                throw new AssertionError("Later-transform rejection removed/faulted the old provider or its hooks");
        } finally {
            instrumentation.removeTransformer(later); instrumentation.retransformClasses(target);
        }
        try(var candidate=new VehicleDrivetrainProvider()) {
            if(!candidate.preflight(instrumentation,loader,active::capturePreflightInput).supported())
                throw new AssertionError("Removing the later conflict did not restore non-retiring preflight");
        }
    }
    private static long hooks(ClassFile cf,byte[] bytes,String method) {
        if(bytes==null) throw new AssertionError("Missing transformer audit");
        return cf.parse(bytes).methods().stream().flatMap(m->m.code().stream()).flatMap(c->c.elementStream())
            .filter(e -> e instanceof InvokeInstruction call && call.owner().asInternalName().equals("pztools/extensions/api/VehicleHooks")
                && (method==null || call.name().equalsString(method))).count();
    }
    private static long nopsInConstructors(ClassFile cf,byte[] bytes) {
        return cf.parse(bytes).methods().stream().filter(m->m.methodName().equalsString("<init>"))
            .flatMap(m->m.code().stream()).flatMap(c->c.elementStream()).filter(e->e instanceof Instruction i && i.opcode()==Opcode.NOP).count();
    }
}
