import java.lang.classfile.*;
import java.lang.constant.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/** Synthetic archives only; no installed game, class initialization or external class execution. */
public final class OverrideArchiveValidationTest {
    private static final String NAME="archiveprobe.VehicleOverride";
    private static final String ENTRY=NAME.replace('.','/')+".class";
    private static int cases;

    public static void main(String[] args) throws Exception {
        if(args.length!=1) throw new IllegalArgumentException("Expected fixture output directory");
        Path output=Files.createDirectories(Path.of(args[0])).toAbsolutePath();
        byte[] original=probe("baseMarker"),override=probe("overrideMarker");
        Path base=archive(output.resolve("base.jar"),Map.of(ENTRY,original));
        Path root=archive(output.resolve("root.zip"),Map.of(ENTRY,override));
        var checked=VerifyInstalledVehicleBytecode.inspectOverrides(root);
        try(var loader=new VerifyInstalledVehicleBytecode.VerifierLoader(base,checked,OverrideArchiveValidationTest.class.getClassLoader())) {
            loader.verifyOverrideResources();
            Class<?> defined=Class.forName(NAME,false,loader);
            check(defined.getClassLoader()==loader,"override must be defined by the verifier loader");
            check(defined.getDeclaredField("overrideMarker")!=null,"base class must not win");
            loader.requireAppliedOverrides();
            check(loader.loadedOverrideCount()==1,"actual override definition must be counted");
            cases++;
        }
        reject("prefix",()->VerifyInstalledVehicleBytecode.inspectOverrides(
            archive(output.resolve("prefix.zip"),Map.of("release/"+ENTRY,override))));
        reject("mixed root/prefix",()->VerifyInstalledVehicleBytecode.inspectOverrides(
            archive(output.resolve("mixed.zip"),Map.of(ENTRY,override,"release/"+ENTRY,override))));
        reject("malformed class",()->VerifyInstalledVehicleBytecode.inspectOverrides(
            archive(output.resolve("malformed.zip"),Map.of(ENTRY,new byte[]{0,1,2,3}))));
        reject("truncated class",()->VerifyInstalledVehicleBytecode.inspectOverrides(
            archive(output.resolve("truncated.zip"),Map.of(ENTRY,Arrays.copyOf(override,override.length-1)))));
        reject("empty archive",()->VerifyInstalledVehicleBytecode.inspectOverrides(
            archive(output.resolve("empty.zip"),Map.of("README.txt",new byte[]{1}))));
        reject("wrong declared name",()->VerifyInstalledVehicleBytecode.inspectOverrides(
            archive(output.resolve("wrong-name.zip"),Map.of("archiveprobe/Different.class",override))));
        reject("malformed ZIP",()->{
            Path invalid=output.resolve("invalid.zip"); Files.write(invalid,new byte[]{0,1,2,3});
            VerifyInstalledVehicleBytecode.inspectOverrides(invalid);
        });
        reject("missing archive",()->VerifyInstalledVehicleBytecode.inspectOverrides(output.resolve("missing.zip")));
        try(var parent=new URLClassLoader(new URL[]{base.toUri().toURL()},OverrideArchiveValidationTest.class.getClassLoader())) {
            reject("parent resource shadow",()->{
                try(var loader=new VerifyInstalledVehicleBytecode.VerifierLoader(base,checked,parent)) { loader.verifyOverrideResources(); }
            });
        }
        // A generated parent class can shadow loadClass even without exposing any matching resource.
        ClassLoader generatedParent=new ClassLoader(OverrideArchiveValidationTest.class.getClassLoader()) {
            @Override protected Class<?> findClass(String name) throws ClassNotFoundException {
                if(name.equals(NAME)) return defineClass(name,original,0,original.length);
                throw new ClassNotFoundException(name);
            }
        };
        reject("parent definition without resource",()->{
            try(var loader=new VerifyInstalledVehicleBytecode.VerifierLoader(base,checked,generatedParent)) {
                loader.verifyOverrideResources();
                Class.forName(NAME,false,loader);
            }
        });
        reject("archive not used",()->{
            try(var loader=new VerifyInstalledVehicleBytecode.VerifierLoader(base,checked,OverrideArchiveValidationTest.class.getClassLoader())) {
                loader.verifyOverrideResources(); loader.requireAppliedOverrides();
            }
        });
        try(var loader=new VerifyInstalledVehicleBytecode.VerifierLoader(base,null,OverrideArchiveValidationTest.class.getClassLoader())) {
            loader.verifyOverrideResources(); loader.requireAppliedOverrides();
            Class.forName(NAME,false,loader).getDeclaredField("baseMarker");
            check(loader.loadedOverrideCount()==0,"default loading must not report an override");
            cases++;
        }
        System.out.println("PASS override archive validation: "+cases+" cases; synthetic classes were defined without initialization");
    }

    private static byte[] probe(String marker) {
        var failure=ClassDesc.of("java.lang.AssertionError");
        return ClassFile.of().build(ClassDesc.of(NAME),b->{
            b.withField(marker,ConstantDescs.CD_int,ClassFile.ACC_PUBLIC);
            b.withMethodBody("<clinit>",MethodTypeDesc.of(ConstantDescs.CD_void),ClassFile.ACC_STATIC,
                code->code.new_(failure).dup().invokespecial(failure,"<init>",MethodTypeDesc.of(ConstantDescs.CD_void)).athrow());
        });
    }
    private static Path archive(Path path,Map<String,byte[]> entries) throws Exception {
        try(var zip=new ZipOutputStream(Files.newOutputStream(path))) {
            for(var entry:entries.entrySet()) {
                zip.putNextEntry(new ZipEntry(entry.getKey())); zip.write(entry.getValue()); zip.closeEntry();
            }
        }
        return path;
    }
    @FunctionalInterface private interface Action { void run() throws Exception; }
    private static void reject(String name,Action action) throws Exception {
        try { action.run(); }
        catch(IllegalArgumentException | java.io.IOException | ClassNotFoundException expected) { cases++; return; }
        throw new AssertionError(name+" was accepted");
    }
    private static void check(boolean condition,String message) { if(!condition) throw new AssertionError(message); }
}
