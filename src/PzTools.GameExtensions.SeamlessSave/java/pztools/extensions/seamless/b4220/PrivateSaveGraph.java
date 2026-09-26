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
    public static final List<MethodRef> SOURCES = List.of(WINDOW, CELL, MAP, CHUNK);
    private static final MethodRef THUMB = new MethodRef("zombie/savefile/SavefileThumbnail", "create", "()V");
    private static final ClassDesc LOOKUP = ClassDesc.of("java.lang.invoke.MethodHandles$Lookup");
    private static final DirectMethodHandleDesc LINK = MethodHandleDesc.ofMethod(DirectMethodHandleDesc.Kind.STATIC,
        ClassDesc.of("pztools.extensions.api.PrivateMethodLinkage"), "link", MethodTypeDesc.of(
            ClassDesc.of("java.lang.invoke.CallSite"), LOOKUP, CD_String, ClassDesc.of("java.lang.invoke.MethodType"), CD_int));
    private final MethodHandle entry;
    private PrivateSaveGraph(MethodHandle entry) { this.entry = entry; }
    @Override public void saveForBackup() throws Throwable { entry.invokeExact(true); }

    public static PrivateSaveGraph create(ClassLoader loader, Map<String, byte[]> sources, MethodHandle write) throws Throwable {
        MethodHandles.Lookup lookup = gameLookup(Class.forName(WINDOW.owner.replace('/', '.'), false, loader));
        MethodHandle chunk = copy(loader, lookup, sources.get(CHUNK.owner), CHUNK, WRITE, write, 2);
        MethodHandle map = copy(loader, lookup, sources.get(MAP.owner), MAP, CHUNK, chunk, 1);
        MethodHandle cell = copy(loader, lookup, sources.get(CELL.owner), CELL, MAP, map, 1);
        MethodHandle root = copy(loader, lookup, sources.get(WINDOW.owner), WINDOW, CELL, cell, 1);
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
                                     MethodRef replacement, MethodHandle target, int expected) throws Throwable {
        var cf = format(loader);
        MethodModel method = method(cf, bytes, source);
        MethodTypeDesc signature = effectiveType(method, source);
        Class<?> owner = Class.forName(source.owner.replace('/', '.'), false, loader);
        var privateLookup = MethodHandles.privateLookupIn(owner, full);
        byte[] generated = build(cf, method, source, replacement, expected);
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
        var hidden = privateLookup.defineHiddenClassWithClassData(generated, List.of(linkedTarget), false, MethodHandles.Lookup.ClassOption.NESTMATE);
        return hidden.findStatic(hidden.lookupClass(), "run", MethodType.fromMethodDescriptorString(signature.descriptorString(), loader));
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
    private static byte[] build(ClassFile cf, MethodModel method, MethodRef source, MethodRef redirect, int expected) {
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
                    } else c.with(e);
                }));
        });
    }
}
