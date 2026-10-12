package zombie.core;

/** Synthetic: the screen's size, and the count that has the lighting work every square again. */
public final class Core {
    private static final Core INSTANCE = new Core();
    public static Core getInstance() { return INSTANCE; }
    public int getScreenWidth() { return 1600; }
    public int getScreenHeight() { return 1000; }
    /** The option of the dyslexic font, as a test sets it. */
    public static boolean dyslexicFont;
    public static float blinkAlpha = 1f;
    public boolean getOptionEnableDyslexicFont() { return dyslexicFont; }
    /** The projection and model view the interface is drawn with. */
    public final zombie.core.opengl.MatrixStack projectionMatrixStack = new zombie.core.opengl.MatrixStack(),
        modelViewMatrixStack = new zombie.core.opengl.MatrixStack();
}
