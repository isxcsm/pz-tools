package pzopt;

/** Synthetic: PZ Optimization's pixel light, whose pass mode links a program of its own from its pass source. */
public final class PixelLight {
    public static String PASS_FRAG = "";

    public static final class Gl {
        public int program;

        public boolean init() {
            program = AmbientOcclusion.link("vert", PASS_FRAG);
            return program != 0;
        }
    }
}
