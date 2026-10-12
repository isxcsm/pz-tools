package se.krka.kahlua.j2se;

import se.krka.kahlua.vm.*;

/** Synthetic. */
public final class J2SEPlatform implements Platform {
    @Override public KahluaTable newTable() { return new KahluaTableImpl(); }
    @Override public KahluaTable newEnvironment() { return new KahluaTableImpl(); }
}
