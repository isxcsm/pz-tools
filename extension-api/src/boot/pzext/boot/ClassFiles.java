package pzext.boot;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassHierarchyResolver;

/** The class file reader and writer the hooks use. */
final class ClassFiles {
    private ClassFiles() { }

    /**
     * New stack maps need the game's class hierarchy. It is read from the class files themselves: loading classes from
     * inside a transformer, perhaps during another agent's retransformation, can fail or deadlock, and runs every
     * agent's transformers on the classes it loads. Loading stays only as the last resort, for a class whose file
     * cannot be read.
     */
    static ClassFile of(ClassLoader loader) {
        return ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.defaultResolver()
            .orElse(ClassHierarchyResolver.ofResourceParsing(loader)).orElse(ClassHierarchyResolver.ofClassLoading(loader)).cached()));
    }
}
