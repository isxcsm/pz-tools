package pztools.extensions.seamless.b4220;

import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;
import static java.lang.constant.ConstantDescs.*;

/** Read-only native entry/error observation. Does not acquire locks, set flags or skip native work. */
public final class NativeSaveObservation {
    private static final ClassDesc HOOK = ClassDesc.of("pztools.extensions.api.GameHooks");
    public static byte[] transform(byte[] bytes, ClassLoader loader) {
        var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
        var model = cf.parse(bytes);
        var methods = model.methods().stream().filter(m -> m.methodName().equalsString("runInner")
            && m.methodType().equalsString("()V")).toList();
        if (methods.size() != 1 || methods.getFirst().code().isEmpty()) throw new IllegalArgumentException("Native worker layout changed");
        var body = methods.getFirst().code().orElseThrow();
        if (body.elementStream().filter(NativeSaveObservation::nativeCall).count() != 1
                || body.elementStream().anyMatch(e -> e instanceof InvokeInstruction i
                    && i.owner().asInternalName().equals("pztools/extensions/api/GameHooks")))
            throw new IllegalArgumentException("Native worker entry is not unique or is already observed");
        return cf.transformClass(model, ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("runInner") && m.methodType().equalsString("()V"),
            CodeTransform.ofStateful(() -> new CodeTransform() {
                Label start, end, handler;
                int error;
                public void atStart(CodeBuilder c) {
                    start=c.newLabel(); end=c.newLabel(); handler=c.newLabel(); error=c.allocateLocal(TypeKind.REFERENCE);
                    c.labelBinding(start);
                }
                public void accept(CodeBuilder c, CodeElement e) {
                    if (nativeCall(e)) c.ldc(OwnedNativeSave.POINT).invokestatic(HOOK,"enter",MethodTypeDesc.of(CD_void,CD_String));
                    c.with(e);
                    if (e instanceof FieldInstruction f && f.opcode()==Opcode.PUTFIELD
                            && f.owner().asInternalName().equals("zombie/MapCollisionData$MCDThread")
                            && f.name().equalsString("save") && f.type().equalsString("Z"))
                        c.ldc(OwnedNativeSave.POINT).aconst_null().invokestatic(HOOK,"exit",MethodTypeDesc.of(CD_void,CD_String,ClassDesc.of("java.lang.Throwable")));
                }
                public void atEnd(CodeBuilder c) {
                    c.labelBinding(end).labelBinding(handler).astore(error).ldc(OwnedNativeSave.POINT).aload(error)
                        .invokestatic(HOOK,"exit",MethodTypeDesc.of(CD_void,CD_String,ClassDesc.of("java.lang.Throwable")))
                        .aload(error).athrow().exceptionCatchAll(start,end,handler);
                }
            })));
    }
    private static boolean nativeCall(CodeElement e) {
        return e instanceof InvokeInstruction i && i.opcode()==Opcode.INVOKESTATIC
            && i.owner().asInternalName().equals("zombie/MapCollisionData") && i.name().equalsString("n_save")
            && i.type().equalsString("()V");
    }
}