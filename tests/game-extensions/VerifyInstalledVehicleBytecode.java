import java.lang.classfile.*;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.constant.ClassDesc;
import java.lang.constant.MethodTypeDesc;
import java.lang.instrument.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.*;
import java.util.zip.ZipFile;
import pztools.extensions.vehicle.*;

/** Read-only: loads metadata in a separate JVM, never starts/attaches to a game or invokes vehicle physics. */
public final class VerifyInstalledVehicleBytecode {
    public static void main(String[] args) throws Exception {
        if(args.length<1 || args.length>2) throw new IllegalArgumentException("Expected installed projectzomboid.jar path and optional override JAR/ZIP path");
        Path jar=Path.of(args[0]).toAbsolutePath();
        OverrideArchive overrides=args.length==2?inspectOverrides(Path.of(args[1])):null;
        try(var loader=new VerifierLoader(jar,overrides,VerifyInstalledVehicleBytecode.class.getClassLoader())) {
            loader.verifyOverrideResources();
            byte[] original=VehicleDrivetrainProvider.verifyResources(loader);
            byte[] transformed=VehicleBytecode.transform(original,loader);
            var cf=ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
            var errors=cf.verify(transformed);
            if(!errors.isEmpty()) throw new AssertionError(errors.toString());
            VehicleDrivetrainProvider.verifyAccess(loader);
            try { VehicleBytecode.transform(transformed,loader); throw new AssertionError("Duplicate transformation accepted"); }
            catch(IllegalArgumentException expected) { }
            loader.requireAppliedOverrides();
            System.out.println("VERIFIED (not executed): controller resource, resolved-mode/offroad transform, JVM verification, access contracts and duplicate rejection");
            System.out.println("Steering key bindings (optional, for precise key timing): "
                +(VehicleDrivetrainProvider.verifySteeringBindings(loader)?"resolved":"NOT RESOLVED - keys will be timed per frame"));
            System.out.println("Area light (optional, light around the vehicle): "
                +(VehicleDrivetrainProvider.verifyAreaLight(loader)?"resolved":"NOT RESOLVED - the light stays off"));
            System.out.println("Controller canonical SHA-256: "+VehicleBytecode.sha256(VehicleBytecode.fingerprint(original,loader)));
            if(PrivateValidationAgent.instrumentation!=null) lifecycle(PrivateValidationAgent.instrumentation,loader,original);
            if(overrides!=null) System.out.println("Override evidence (no class initialization): "+overrides.classes().size()
                +" class paths validated; "+loader.loadedOverrideCount()+" classes defined from "+overrides.path());
        }
    }

    record OverrideArchive(Path path,Set<String> classes) { }

    /** Validate every declared class path, not just the controller or the presence of a .class suffix. */
    static OverrideArchive inspectOverrides(Path path) throws Exception {
        if(!Files.isRegularFile(path)) throw new IllegalArgumentException("Override archive does not exist: "+path);
        path=path.toRealPath();
        var classes=new TreeSet<String>();
        try(var archive=new ZipFile(path.toFile())) {
            var entries=archive.entries();
            long total=0;
            while(entries.hasMoreElements()) {
                var entry=entries.nextElement();
                if(entry.isDirectory() || !entry.getName().endsWith(".class")) continue;
                byte[] bytes;
                try(var input=archive.getInputStream(entry)) { bytes=input.readNBytes(4*1024*1024+1); }
                total+=bytes.length;
                if(bytes.length>4*1024*1024 || total>128L*1024*1024 || classes.size()>=4096)
                    throw new IllegalArgumentException("Override class data exceeds verifier limits: "+entry.getName());
                String internal;
                try {
                    var model=ClassFile.of().parse(bytes);
                    internal=model.thisClass().asInternalName();
                    // ClassModel is lazy: walk method bodies so a readable name cannot hide truncated code.
                    model.attributes().size();
                    for(var field:model.fields()) field.attributes().size();
                    for(var method:model.methods()) {
                        method.attributes().size();
                        method.code().ifPresent(code->code.forEach(element->{ }));
                    }
                } catch(IllegalArgumentException | IndexOutOfBoundsException malformed) {
                    throw new IllegalArgumentException("Malformed override class: "+entry.getName(),malformed);
                }
                if(!entry.getName().equals(internal+".class"))
                    throw new IllegalArgumentException("Override class path must match its declared name: "+entry.getName()+"; expected "+internal+".class");
                if(!classes.add(internal.replace('/','.')))
                    throw new IllegalArgumentException("Duplicate override class: "+entry.getName());
            }
        }
        if(classes.isEmpty()) throw new IllegalArgumentException("Override archive contains no class files: "+path);
        return new OverrideArchive(path,Set.copyOf(classes));
    }

    /** Keep normal parent-first loading; observe its result instead of forcing an override to win. */
    static final class VerifierLoader extends URLClassLoader {
        private final OverrideArchive overrides;
        private final Set<String> loadedOverrides=ConcurrentHashMap.newKeySet();
        VerifierLoader(Path jar,OverrideArchive overrides,ClassLoader parent) throws Exception {
            super(overrides==null?new URL[]{jar.toUri().toURL()}
                :new URL[]{overrides.path().toUri().toURL(),jar.toUri().toURL()},parent);
            this.overrides=overrides;
        }
        void verifyOverrideResources() throws Exception {
            if(overrides==null) return;
            for(String name:overrides.classes()) {
                String resource=name.replace('.','/')+".class";
                URL resolved=getResource(resource);
                if(resolved==null || !(resolved.openConnection() instanceof JarURLConnection connection)
                        || !resource.equals(connection.getEntryName()) || !fromOverrides(connection.getJarFileURL()))
                    throw new IllegalArgumentException("Override resource is shadowed or unavailable: "+resource);
            }
        }
        @Override protected Class<?> loadClass(String name,boolean resolve) throws ClassNotFoundException {
            Class<?> type=super.loadClass(name,resolve);
            if(overrides!=null && overrides.classes().contains(name)) {
                var source=type.getProtectionDomain().getCodeSource();
                if(type.getClassLoader()!=this || source==null || !fromOverrides(source.getLocation()))
                    throw new ClassNotFoundException("Override class was defined by another loader or source: "+name);
                loadedOverrides.add(name);
            }
            return type;
        }
        private boolean fromOverrides(URL location) {
            if(location==null || !location.getProtocol().equals("file")) return false;
            try { return Files.isSameFile(overrides.path(),Path.of(location.toURI())); }
            catch(Exception unreadable) { return false; }
        }
        int loadedOverrideCount() { return loadedOverrides.size(); }
        void requireAppliedOverrides() {
            if(overrides!=null && loadedOverrides.isEmpty())
                throw new IllegalArgumentException("No classes from the override archive were used by vehicle verification");
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
                    byte[] unrelated=withUnrelatedNops(cf,bytes);
                    return conflict.get()?withConflictingControlCall(cf,unrelated):unrelated;
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
                                return withConflictingControlCall(cf,bytes);
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
                        if(!java.util.Arrays.equals(VehicleBytecode.fingerprint(withUnrelatedNops(cf,original),loader),VehicleBytecode.fingerprint(observed.get(),loader)))
                            throw new AssertionError("Retirement changed externally transformed controller methods");
                        long before=nopsInConstructors(cf,original), after=nopsInConstructors(cf,observed.get());
                        if(after<=before) throw new AssertionError("Retirement removed the unrelated constructor transformer");
                        if(nopsInUpdate(cf,observed.get())<=nopsInUpdate(cf,original))
                            throw new AssertionError("Retirement removed the unrelated update transformer");
                    } finally { instrumentation.removeTransformer(audit); }
                } finally { provider.close(); }
            }
            var provider=new VehicleDrivetrainProvider();
            try {
                if(!provider.initialize(instrumentation,loader).supported()) throw new AssertionError("Conflict fixture admission rejected early");
                conflict.set(true); instrumentation.retransformClasses(target);
                if(provider.failureReason()==null) throw new AssertionError("Live conflicting control call was not reported");
            } finally { provider.close(); }
            if(foreignFailure.get()!=null) throw new AssertionError("Foreign transformer failed",foreignFailure.get());
            if(foreignCalls.get()<12) throw new AssertionError("External transformer was not retained across retirement");
            System.out.println("VERIFIED (offline JVM, no game invocation): three inert install/retransform/retire cycles, non-retiring preflight including later-transform rejection, unrelated constructor/update preservation, live control-call conflict rejection");
        } finally {
            instrumentation.removeTransformer(foreign); instrumentation.retransformClasses(target);
        }
    }
    private static byte[] withUnrelatedNops(ClassFile cf,byte[] bytes) {
        return cf.transformClass(cf.parse(bytes),ClassTransform.transformingMethodBodies(
            m->m.methodName().equalsString("<init>") || m.methodName().equalsString("update") && m.methodType().equalsString("()V"),
            CodeTransform.ofStateful(()->new CodeTransform() {
                @Override public void atStart(CodeBuilder b) { b.nop(); }
                @Override public void accept(CodeBuilder b,CodeElement e) { b.with(e); }
            })));
    }
    /** Same stack shape, but removes the forward call and adds a second reverse call. Never executed. */
    private static byte[] withConflictingControlCall(ClassFile cf,byte[] bytes) {
        AtomicInteger changed=new AtomicInteger();
        byte[] result=cf.transformClass(cf.parse(bytes),ClassTransform.transformingMethodBodies(
            m->m.methodName().equalsString("update") && m.methodType().equalsString("()V"),(b,e)-> {
                if(e instanceof InvokeInstruction call && call.owner().asInternalName().equals(VehicleBytecode.TARGET)
                        && call.name().equalsString("control_ForwardNew") && call.type().equalsString("(F)V")) {
                    var owner=ClassDesc.of(VehicleBytecode.TARGET.replace('/','.'));
                    var type=MethodTypeDesc.ofDescriptor("(F)V");
                    if(call.opcode()==Opcode.INVOKEVIRTUAL) b.invokevirtual(owner,"control_Reverse",type);
                    else if(call.opcode()==Opcode.INVOKESPECIAL) b.invokespecial(owner,"control_Reverse",type);
                    else throw new AssertionError("Unexpected control-call opcode: "+call.opcode());
                    changed.incrementAndGet();
                } else b.with(e);
            }));
        if(changed.get()!=1) throw new AssertionError("Expected exactly one forward control call, found "+changed.get());
        return result;
    }
    private static void rejectLaterTransformer(Instrumentation instrumentation,ClassLoader loader,Class<?> target,
            VehicleDrivetrainProvider active,ClassFile cf) throws Exception {
        AtomicReference<byte[]> laterOutput=new AtomicReference<>();
        AtomicReference<Throwable> laterFailure=new AtomicReference<>();
        AtomicBoolean conflict=new AtomicBoolean();
        ClassFileTransformer later=new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner,String name,Class<?> type,java.security.ProtectionDomain domain,byte[] bytes) {
                if(owner!=loader || type!=target) return null;
                try {
                    byte[] result=conflict.get()?withConflictingControlCall(cf,bytes):withUnrelatedNops(cf,bytes);
                    laterOutput.set(result); return result;
                } catch(Throwable failure) { laterFailure.set(failure); return null; }
            }
        };
        instrumentation.addTransformer(later,true);
        try(var candidate=new VehicleDrivetrainProvider()) {
            if(!candidate.preflight(instrumentation,loader,active::capturePreflightInput).supported())
                throw new AssertionError("An unrelated later NOP change was rejected");
            conflict.set(true);
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
    private static long nopsInUpdate(ClassFile cf,byte[] bytes) {
        return cf.parse(bytes).methods().stream().filter(m->m.methodName().equalsString("update") && m.methodType().equalsString("()V"))
            .flatMap(m->m.code().stream()).flatMap(c->c.elementStream()).filter(e->e instanceof Instruction i && i.opcode()==Opcode.NOP).count();
    }
}
