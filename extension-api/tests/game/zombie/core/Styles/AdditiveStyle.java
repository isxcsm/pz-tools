package zombie.core.Styles;

/** Synthetic: the blending of premultiplied colours (one, one minus the source's alpha). */
public final class AdditiveStyle extends AbstractStyle {
    public static final AdditiveStyle instance = new AdditiveStyle();

    @Override public String toString() { return "AdditiveStyle"; }
}
