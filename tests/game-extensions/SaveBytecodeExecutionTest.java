import pztools.extensions.api.GameHooks;
import pztools.extensions.seamless.b4220.SaveBytecode;
import java.lang.classfile.*;
import java.lang.constant.*;
import java.lang.reflect.InvocationTargetException;

/** Executes transformed generated classes, without attaching to or loading any game installation. */
public final class SaveBytecodeExecutionTest {
    public static boolean throwing, suppress;
    public static int previews, enters, exits;
    public static Throwable lastFailure;
    public static void main(String[] args) throws Exception {
        var cf = ClassFile.of();
        var loader = new Loader();
        ClassDesc self = ClassDesc.of("SaveBytecodeExecutionTest");
        ClassDesc thumbnail = ClassDesc.of("zombie.savefile.SavefileThumbnail");
        loader.define("zombie.savefile.SavefileThumbnail", cf.build(thumbnail, b -> b.withFlags(ClassFile.ACC_PUBLIC).withMethodBody(
            "create", MethodTypeDesc.of(ConstantDescs.CD_void), ClassFile.ACC_PUBLIC | ClassFile.ACC_STATIC,
            code -> code.getstatic(self, "previews", ConstantDescs.CD_int).iconst_1().iadd()
                .putstatic(self, "previews", ConstantDescs.CD_int).return_())));
        byte[] window = cf.build(ClassDesc.of("GeneratedWindow"), b -> b.withFlags(ClassFile.ACC_PUBLIC).withMethodBody("save",
            MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_boolean), ClassFile.ACC_PUBLIC | ClassFile.ACC_STATIC,
            code -> code.invokestatic(thumbnail, "create", MethodTypeDesc.of(ConstantDescs.CD_void)).return_()));
        var observer = new GameHooks.Observer() { public boolean suppress() { return suppress; } };
        GameHooks.register("pztools.save.thumbnail.v1", observer);
        try {
            var save = loader.define("GeneratedWindow", SaveBytecode.transform("zombie/GameWindow", window, loader))
                .getMethod("save", boolean.class);
            save.invoke(null, true); suppress = true; save.invoke(null, true);
            check(previews == 1, "Preview interception must not skip the ordinary call");
        } finally { GameHooks.unregister("pztools.save.thumbnail.v1", observer); }
        byte[] drain = cf.build(ClassDesc.of("GeneratedDrain"), b -> b.withFlags(ClassFile.ACC_PUBLIC).withMethodBody("updateWorldStreamer",
            MethodTypeDesc.of(ConstantDescs.CD_void), ClassFile.ACC_PUBLIC | ClassFile.ACC_STATIC, code -> {
                Label end = code.newLabel();
                ClassDesc failure = ClassDesc.of("java.lang.IllegalStateException");
                code.getstatic(self, "throwing", ConstantDescs.CD_boolean).ifeq(end)
                    .new_(failure).dup().invokespecial(failure, "<init>", MethodTypeDesc.of(ConstantDescs.CD_void))
                    .athrow().labelBinding(end).return_();
            }));
        var drains = new GameHooks.Observer() {
            public void enter() { enters++; }
            public void exit(Throwable error) { exits++; lastFailure = error; }
        };
        GameHooks.register("pztools.save.players-drain.v1", drains);
        try {
            var update = loader.define("GeneratedDrain", SaveBytecode.transform("zombie/savefile/PlayerDB", drain, loader))
                .getMethod("updateWorldStreamer");
            update.invoke(null); check(enters == 1 && exits == 1 && lastFailure == null, "Normal drain completion");
            throwing = true;
            try { update.invoke(null); throw new AssertionError("Exception swallowed by hook"); }
            catch (InvocationTargetException expected) { check(expected.getCause() == lastFailure, "Original error identity"); }
            check(enters == 2 && exits == 2, "Exception must signal completion once");
        } finally { GameHooks.unregister("pztools.save.players-drain.v1", drains); }
        System.out.println("PASS: transformed preview guard, successful drain, exceptional drain");
    }
    private static final class Loader extends ClassLoader {
        Class<?> define(String name, byte[] bytes) { return defineClass(name, bytes, 0, bytes.length); }
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
