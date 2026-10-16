package zombie.core.skinnedmodel.model;

import java.util.ArrayList;
import java.util.List;
import zombie.core.skinnedmodel.animation.AnimationPlayer;
import zombie.core.textures.ColorInfo;
import zombie.iso.SpriteModel;

/** Synthetic: the game's model outline, queued; each call kept as {model, x, y, z, r, g, b, a, offset}. */
public final class IsoObjectModelDrawer {
    public enum RenderStatus { Loading, Ready }
    public static final List<Object[]> outlines = new ArrayList<>();
    /** The light the last model object was drawn with, as the game takes it for the model's ambient colour. */
    public static float ambientR, ambientG, ambientB;
    public static RenderStatus renderMain(SpriteModel model, float x, float y, float z, ColorInfo light, float alpha) {
        return renderMain(model, x, y, z, light, alpha, null, null, false, true);
    }
    public static RenderStatus renderMain(SpriteModel model, float x, float y, float z, ColorInfo light, float alpha, SpriteModel parent,
            org.joml.Matrix4f attached, boolean outline, boolean world) {
        ambientR = light.r; ambientG = light.g; ambientB = light.b;
        return RenderStatus.Ready;
    }
    /** A model object drawn in an animation (a door that swings): the same light, taken for the model's ambient colour. */
    public static RenderStatus renderMain(SpriteModel model, float x, float y, float z, ColorInfo light, float alpha, AnimationPlayer animation) {
        ambientR = light.r; ambientG = light.g; ambientB = light.b;
        return RenderStatus.Ready;
    }
    public static RenderStatus renderMainOutline(SpriteModel model, float x, float y, float z, ColorInfo colour, float offset) {
        outlines.add(new Object[] { model, x, y, z, colour.r, colour.g, colour.b, colour.a, offset });
        return RenderStatus.Ready;
    }
}
