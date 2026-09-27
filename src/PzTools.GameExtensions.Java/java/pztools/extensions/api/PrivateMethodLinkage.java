package pztools.extensions.api;

import java.lang.invoke.*;

/** Links only the immutable handles carried by one hidden companion; no global dispatch or game state. */
public final class PrivateMethodLinkage {
    private PrivateMethodLinkage() { }
    public static CallSite link(MethodHandles.Lookup caller, String name, MethodType type, int index)
            throws IllegalAccessException {
        if (!caller.lookupClass().isHidden()) throw new IllegalAccessException("Private companion required");
        MethodHandle target = MethodHandles.classDataAt(caller, "_", MethodHandle.class, index);
        return new ConstantCallSite(target.asType(type));
    }
}
