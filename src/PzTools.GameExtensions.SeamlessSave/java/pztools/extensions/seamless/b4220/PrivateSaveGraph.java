package pztools.extensions.seamless.b4220;

import pztools.extensions.seamless.VersionedSaveEntry;
import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;
import java.lang.invoke.*;
import java.lang.reflect.Modifier;
import java.util.*;
import static java.lang.constant.ConstantDescs.*;

/** Copy four pinned method bodies into private nestmates, not into the installed game classes. */
public final class PrivateSaveGraph implements VersionedSaveEntry {
    public record MethodRef(String owner, String name, String descriptor) { }
    public static final MethodRef WINDOW = new MethodRef("zombie/GameWindow", "save", "(Z)V");
    public static final MethodRef CELL = new MethodRef("zombie/iso/IsoCell", "save", "(Ljava/io/DataOutputStream;Z)V");
    public static final MethodRef MAP = new MethodRef("zombie/iso/IsoChunkMap", "Save", "()V");
    public static final MethodRef CHUNK = new MethodRef("zombie/iso/IsoChunk", "Save", "(Z)V");
    public static final MethodRef WRITE = new MethodRef("zombie/iso/IsoChunk", "SafeWrite", "(IILjava/nio/ByteBuffer;)V");
    public static final MethodRef NATIVE = new MethodRef("zombie/MapCollisionData", "save", "()V");
    public static final List<MethodRef> SOURCES = List.of(WINDOW, CELL, MAP, CHUNK, NATIVE);
    private static final MethodRef THUMB = new MethodRef("zombie/savefile/SavefileThumbnail", "create", "()V");
    private static final ClassDesc LOOKUP = ClassDesc.of("java.lang.invoke.MethodHandles$Lookup");
    private static final DirectMethodHandleDesc LINK = MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.STATIC,
        ClassDesc.of("pztools.extensions.api.PrivateMethodLinkage"), "link", MethodTypeDesc.of(
            ClassDesc.of("java.lang.invoke.CallSite"), LOOKUP, CD_String, ClassDesc.of("java.lang.invoke.MethodType"), CD_int));
    private final MethodHandle entry;
    private PrivateSaveGraph(MethodHandle entry) { this.entry = entry; }
    @Override public void saveForBackup() throws Throwable { entry.invokeExact(true); }

    public static PrivateSaveGraph create(ClassLoader loader, Map<String, byte[]> sources, MethodHandle write) throws Throwable {
        return create(loader, sources, write, null);
    }
    static PrivateSaveGraph create(ClassLoader loader, Map<String, byte[]> sources, MethodHandle write,
                                   CaptureTimings timings) throws Throwable {
        return create(loader, sources, write, timings, null);
    }
    static PrivateSaveGraph create(ClassLoader loader, Map<String, byte[]> sources, MethodHandle write,
                                   CaptureTimings timings, OwnedNativeSave nativeSave) throws Throwable {
        MethodHandles.Lookup lookup = gameLookup(Class.forName(WINDOW.owner.replace('/', '.'), false, loader));
        MethodHandle chunk = copy(loader, lookup, sources.get(CHUNK.owner), CHUNK, WRITE, timings == null ? write : timings.write(write), 2, null, null);
        MethodHandle map = copy(loader, lookup, sources.get(MAP.owner), MAP, CHUNK, timings == null ? chunk : timings.chunk(chunk), 1, null, null);
        MethodHandle cell = copy(loader, lookup, sources.get(CELL.owner), CELL, MAP, map, 1, null, null);
        MethodHandle nativeEntry = nativeSave == null ? null : copyNative(loader, lookup, sources.get(NATIVE.owner), nativeSave);
        MethodHandle root = copy(loader, lookup, sources.get(WINDOW.owner), WINDOW, CELL, cell, 1, timings, nativeEntry);
        return new PrivateSaveGraph(root);
    }

    // One private helper in the game's unnamed module obtains a full lookup. No new members are added to GameWindow.
    private static MethodHandles.Lookup gameLookup(Class<?> anchor) throws Throwable {
        var cf = ClassFile.of();
        ClassDesc name = ClassDesc.of(anchor.getPackageName() + ".PzToolsSaveAccess$" + UUID.randomUUID().toString().replace("-", ""));
        byte[] bytes = cf.build(name, b -> b.withFlags(ClassFile.ACC_FINAL | ClassFile.ACC_SUPER)
            .withMethodBody("lookup", MethodTypeDesc.of(LOOKUP), ClassFile.ACC_STATIC | ClassFile.ACC_PRIVATE,
                c -> c.invokestatic(ClassDesc.of("java.lang.invoke.MethodHandles"), "lookup", MethodTypeDesc.of(LOOKUP)).areturn()));
        var packageLookup = MethodHandles.privateLookupIn(anchor, MethodHandles.lookup());
        Class<?> helper = packageLookup.defineClass(bytes);
        var privateLookup = MethodHandles.privateLookupIn(helper, MethodHandles.lookup());
        return (MethodHandles.Lookup)privateLookup.findStatic(helper, "lookup", MethodType.methodType(MethodHandles.Lookup.class)).invokeExact();
    }

    private static MethodHandle copy(ClassLoader loader, MethodHandles.Lookup full, byte[] bytes, MethodRef source,
                                     MethodRef replacement, MethodHandle target, int expected, CaptureTimings timings, MethodHandle nativeEntry) throws Throwable {
        var cf = format(loader);
        MethodModel method = method(cf, bytes, source);
        MethodTypeDesc signature = effectiveType(method, source);
        Class<?> owner = Class.forName(source.owner.replace('/', '.'), false, loader);
        var privateLookup = MethodHandles.privateLookupIn(owner, full);
        var extraCalls = new ArrayList<MethodRef>();
        var extraTargets = new ArrayList<MethodHandle>();
        if (timings != null && source.equals(WINDOW)) {
            for (String type : List.of("zombie/characters/animals/AnimalPopulationManager", "zombie/MapCollisionData")) {
                var ref = new MethodRef(type, "save", "()V");
                if (method.code().orElseThrow().elementStream().anyMatch(e -> call(e, ref))) {
                    Class<?> targetClass = Class.forName(type.replace('/', '.'), false, loader);
                    var original = MethodHandles.privateLookupIn(targetClass, full)
                        .findVirtual(targetClass, "save", MethodType.methodType(void.class));
                    extraCalls.add(ref);
                    MethodHandle chosen = original;
                    if (ref.equals(NATIVE) && nativeEntry != null) {
                        var exact = MethodHandles.lookup().findStatic(PrivateSaveGraph.class, "exactReceiver",
                            MethodType.methodType(boolean.class,Class.class,Object.class)).bindTo(targetClass)
                            .asType(MethodType.methodType(boolean.class,targetClass));
                        chosen = MethodHandles.guardWithTest(exact,nativeEntry,original);
                    }
                    extraTargets.add(timings.nativeCall(chosen, type.contains("animals")));
                }
            }
        }
        byte[] generated = build(cf, method, source, replacement, expected, extraCalls);
        if (!cf.verify(generated).isEmpty()) throw new IllegalArgumentException("Private save body failed verification: " + source);
        MethodHandle linkedTarget = target;
        Class<?> redirectOwner = Class.forName(replacement.owner.replace('/', '.'), false, loader);
        MethodType redirectType = MethodType.fromMethodDescriptorString(replacement.descriptor, loader);
        if (!java.lang.reflect.Modifier.isStatic(redirectOwner.getDeclaredMethod(replacement.name, redirectType.parameterArray()).getModifiers())) {
            MethodHandle originalVirtual = MethodHandles.privateLookupIn(redirectOwner, full).findVirtual(redirectOwner, replacement.name, redirectType);
            MethodHandle test = MethodHandles.lookup().findStatic(PrivateSaveGraph.class, "exactReceiver", MethodType.methodType(boolean.class, Class.class, Object.class))
                .bindTo(redirectOwner).asType(MethodType.methodType(boolean.class, redirectOwner));
            linkedTarget = MethodHandles.guardWithTest(test, target, originalVirtual);
        }
        var targets = new ArrayList<MethodHandle>(); targets.add(linkedTarget); targets.addAll(extraTargets);
        var hidden = privateLookup.defineHiddenClassWithClassData(generated, List.copyOf(targets), false, MethodHandles.Lookup.ClassOption.NESTMATE);
        return hidden.findStatic(hidden.lookupClass(), "run", MethodType.fromMethodDescriptorString(signature.descriptorString(), loader));
    }
    private static MethodHandle copyNative(ClassLoader loader, MethodHandles.Lookup full, byte[] bytes,
                                          OwnedNativeSave operation) throws Throwable {
        var cf=format(loader); MethodModel source=method(cf,bytes,NATIVE);
        Class<?> owner=Class.forName(NATIVE.owner.replace('/','.'),false,loader);
        MethodType type=MethodType.methodType(void.class,owner), decision=MethodType.methodType(boolean.class,owner);
        var before=MethodHandles.lookup().findVirtual(OwnedNativeSave.class,"before",MethodType.methodType(void.class,Object.class))
            .bindTo(operation).asType(type);
        var defer=MethodHandles.lookup().findVirtual(OwnedNativeSave.class,"defer",MethodType.methodType(boolean.class,Object.class))
            .bindTo(operation).asType(decision);
        byte[] generated=cf.build(ClassDesc.of("zombie.MapCollisionData$PzToolsPrivateSave"), b -> {
            b.withFlags(ClassFile.ACC_FINAL|ClassFile.ACC_SUPER);
            b.withMethod("run",MethodTypeDesc.ofDescriptor(type.descriptorString()),ClassFile.ACC_PUBLIC|ClassFile.ACC_STATIC,
                m -> m.transformCode(source.code().orElseThrow(),CodeTransform.ofStateful(() -> new CodeTransform(){
                    boolean flagRead; int redirects;
                    public void atStart(CodeBuilder c){
                        c.aload(0).invokedynamic(DynamicCallSiteDesc.of(LINK,"privateNativeStart",MethodTypeDesc.ofDescriptor(type.descriptorString()),0));
                    }
                    public void accept(CodeBuilder c,CodeElement e){
                        c.with(e);
                        if(flagRead && e instanceof BranchInstruction branch && branch.opcode()==Opcode.IFEQ){
                            c.aload(0).invokedynamic(DynamicCallSiteDesc.of(LINK,"privateNativeWait",MethodTypeDesc.ofDescriptor(decision.descriptorString()),1))
                                .ifne(branch.target()); redirects++;
                        }
                        if(e instanceof Instruction) flagRead=e instanceof FieldInstruction f && f.opcode()==Opcode.GETFIELD
                            && f.owner().asInternalName().equals("zombie/MapCollisionData$MCDThread") && f.name().equalsString("save") && f.type().equalsString("Z");
                    }
                    public void atEnd(CodeBuilder c){if(redirects!=1) throw new IllegalArgumentException("Native wait boundary changed");}
                })));
        });
        if(!cf.verify(generated).isEmpty()) throw new IllegalArgumentException("Private native body verification failed");
        var hidden=MethodHandles.privateLookupIn(owner,full).defineHiddenClassWithClassData(generated,List.of(before,defer),false,MethodHandles.Lookup.ClassOption.NESTMATE);
        return hidden.findStatic(hidden.lookupClass(),"run",type);
    }
    private static boolean exactReceiver(Class<?> type, Object receiver) { return receiver != null && receiver.getClass() == type; }
    public static byte[] methodFingerprint(ClassLoader loader, byte[] bytes, MethodRef source) {
        // Fresh constant pool + generated stack maps normalize retransformation constant-pool reorderings.
        var cf = format(loader);
        MethodModel method = method(cf, bytes, source);
        return cf.build(ClassDesc.of(source.owner.replace('/', '.') + "$PzToolsCanonical"), b ->
            b.withMethod("run", effectiveType(method, source), ClassFile.ACC_STATIC | ClassFile.ACC_PUBLIC,
                m -> m.transformCode(method.code().orElseThrow(), CodeTransform.ACCEPT_ALL)));
    }
    private static ClassFile format(ClassLoader loader) {
        return ClassFile.of(ClassFile.DebugElementsOption.DROP_DEBUG, ClassFile.LineNumbersOption.DROP_LINE_NUMBERS,
            ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
    }
    private static MethodModel method(ClassFile cf, byte[] bytes, MethodRef source) {
        var model = cf.parse(Objects.requireNonNull(bytes));
        if (!model.thisClass().asInternalName().equals(source.owner)) throw new IllegalArgumentException("Unexpected private save owner");
        var methods = model.methods().stream().filter(m -> m.methodName().equalsString(source.name)
            && m.methodType().equalsString(source.descriptor)).toList();
        if (methods.size() != 1 || methods.getFirst().code().isEmpty()
                || (methods.getFirst().flags().flagsMask() & (ClassFile.ACC_SYNCHRONIZED | ClassFile.ACC_NATIVE | ClassFile.ACC_ABSTRACT)) != 0)
            throw new IllegalArgumentException("Unsupported private method body: " + source);
        return methods.getFirst();
    }
    private static MethodTypeDesc effectiveType(MethodModel method, MethodRef source) {
        MethodTypeDesc type = MethodTypeDesc.ofDescriptor(source.descriptor);
        return (method.flags().flagsMask() & ClassFile.ACC_STATIC) != 0 ? type
            : type.insertParameterTypes(0, ClassDesc.of(source.owner.replace('/', '.')));
    }
    private static boolean call(CodeElement e, MethodRef ref) {
        return e instanceof InvokeInstruction i && i.owner().asInternalName().equals(ref.owner)
            && i.name().equalsString(ref.name) && i.type().equalsString(ref.descriptor);
    }
    private static byte[] build(ClassFile cf, MethodModel method, MethodRef source, MethodRef redirect, int expected, List<MethodRef> extraCalls) {
        var body = method.code().orElseThrow();
        if (body.elementStream().filter(e -> call(e, redirect)).count() != expected
                || source.equals(WINDOW) && body.elementStream().filter(e -> call(e, THUMB)).count() != 1)
            throw new IllegalArgumentException("Private call graph changed: " + source);
        return cf.build(ClassDesc.of(source.owner.replace('/', '.') + "$PzToolsPrivateSave"), b -> {
            b.withFlags(ClassFile.ACC_FINAL | ClassFile.ACC_SUPER);
            b.withMethod("run", effectiveType(method, source), ClassFile.ACC_PUBLIC | ClassFile.ACC_STATIC,
                m -> m.transformCode(body, (c, e) -> {
                    // No ambient suppression flag: nested/mod-triggered GameWindow.save still renders normally.
                    if (source.equals(WINDOW) && call(e, THUMB)) return;
                    if (call(e, redirect)) {
                        var invoke = (InvokeInstruction)e;
                        var type = MethodTypeDesc.ofDescriptor(redirect.descriptor);
                        if (invoke.opcode() != Opcode.INVOKESTATIC) type = type.insertParameterTypes(0, ClassDesc.of(redirect.owner.replace('/', '.')));
                        c.invokedynamic(DynamicCallSiteDesc.of(LINK, "privateSave", type, 0));
                    } else {
                        for (int index = 0; index < extraCalls.size(); index++) {
                            MethodRef extra = extraCalls.get(index);
                            if (!call(e, extra)) continue;
                            var type = MethodTypeDesc.ofDescriptor(extra.descriptor)
                                .insertParameterTypes(0, ClassDesc.of(extra.owner.replace('/', '.')));
                            c.invokedynamic(DynamicCallSiteDesc.of(LINK, "measuredSave", type, index + 1));
                            return;
                        }
                        c.with(e);
                    }
                }));
        });
    }
}
