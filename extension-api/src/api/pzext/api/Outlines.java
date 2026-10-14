package pzext.api;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.util.List;
import pzext.boot.Hooks;

/**
 * The game's own object outline ({@code IsoObject.setOutlineHighlight}, {@code setOutlineHighlightCol}) drawn on the objects the
 * game leaves out (docs/design.md, "Outlines"): objects drawn as models (most doors of Build 42, the doors players
 * build, 3D furniture) and vehicles. Nothing is declared: an object outlined by the game, a mod or the API is drawn so.
 *
 * <p>Model objects: the game's per-frame outline pass ({@code FBORenderObjectOutline.renderObject}) draws an outlined object's
 * sprite silhouette and returns at once for one with a sprite model, and the outline its model drawing has is never reached for
 * an object baked into the chunk's texture. The hook at the start of that pass hands a model object here, which queues the
 * game's own model outline ({@code IsoObjectModelDrawer.renderMainOutline}) where {@code IsoObject.renderModel} would: at the
 * square's middle, the surface and render offsets, the render effects' shift, in the outline's colour (blinking as the
 * game's). A double door's halves 2 and 3 draw with the model of their partner (1 and 4), as {@code IsoDoor.renderWallTile}
 * does. As the game's pass, nothing is drawn for an object not shown ({@code ObjectRenderLayer.None} or target alpha 0), and,
 * as the game's own model drawing, nothing while its model animates (a door opening or shut).
 *
 * <p>Vehicles: {@code ModelSlotRenderData.initModel} (the main thread) fills the outline a character's model has from the
 * vehicle (on or off, its colour, whether it is behind the camera's character); {@code renderVehicle} (the render thread) then
 * draws the vehicle's models into the game's outline buffer as {@code performRenderCharacterOutline} draws a character's:
 * the solid shaders, the vehicle's own camera (each model's draw begins and ends it), the depth not written. The game's
 * {@code ModelOutlines} widens and lays it over the frame with every other outline.
 */
final class Outlines implements Hooks.Outlines {
    private static final MethodHandles.Lookup LOOKUP = MethodHandles.publicLookup();
    private static final MethodType OBJ_OBJ = MethodType.methodType(Object.class, Object.class);

    // ---- model objects ----
    private final Class<?> door;
    // IsoObject.getSpriteModel(), getRenderInfo(int), getSprite(), getX/Y/Z(), getRenderYOffset(), getObjectRenderEffectsToApply(),
    // getOutlineHighlightCol(int), isOutlineHlBlink(int); IsoDoor.getDoubleDoorIndex(o), getDoubleDoorObject(o, i).
    private final MethodHandle spriteModel, renderInfo, sprite, xOf, yOf, zOf, yOffset, effects, colourOf, blinks, doubleIndex, doubleObject;
    // ObjectRenderInfo.layer, targetAlpha; ObjectRenderLayer.None; IsoObjectAnimations.getInstance(), getAnimationPlayer(o).
    private final MethodHandle layer, targetAlpha, animations, animationOf;
    private final Object none;
    // IsoSprite.getProperties(); PropertyContainer.isSurfaceOffset(), getSurface(); ObjectRenderEffects.x1, y1.
    private final MethodHandle properties, surfaceOffset, surface, shiftX, shiftY;
    // ColorInfo.setABGR(int), its a; Core.blinkAlpha; IsoObjectModelDrawer.renderMainOutline(model, x, y, z, colour, offset).
    private final MethodHandle setAbgr, setA, blinkAlpha, renderMainOutline;
    // The colour handed to the drawer (it copies it), on the main thread alone.
    private final Object colour;

    // ---- vehicles ----
    // IsoObject.isOutlineHighlight(int); ColorInfo.a, r, g, b.
    private final MethodHandle outlined, getA, getR, getG, getB;
    // ModelSlotRenderData.solidColor, solidColorStatic (read, written), modelData; new Shader(name, static, instanced);
    // Shader.Start(), End(), getShaderProgram(), setTransformMatrix(joml, bool), setMatrixPalette(FloatBuffer, bool);
    // ShaderProgram.setVector4(name, x, y, z, w).
    private final MethodHandle solid, solidStatic, setSolid, setSolidStatic, modelData, newShader, start, end, program, transform,
        palette, vector4;
    // ModelInstanceRenderData.model, matrixPalette, RenderVehicle(data); Model.effect (read, written), isStatic.
    private final MethodHandle model, matrixPalette, renderVehicle, effect, setEffect, isStatic;
    // ModelOutlines.instance, beginRenderOutline(colour, behind, false), fboA; TextureFBO.startDrawing(clear, true), endDrawing();
    // ModelCamera.instance, depthMask.
    private final MethodHandle outlines, begin, fboA, startDrawing, endDrawing, camera, depthMask;
    // GL11; Texture.lastTextureID; SpriteRenderer.ringBuffer, its restoreVbos; GLStateRenderThread.restore().
    private final MethodHandle pushClient, pushAttrib, popAttrib, popClient, enable, disable, blendFunc, alphaFunc, lastTexture,
        ringBuffer, restoreVbos, restore;
    // An identity matrix for the static models (Model.IDENTITY is private), for the render thread alone.
    private final Object identity;

    Outlines(ClassLoader loader) throws ReflectiveOperationException {
        Class<?> object = Game.type(loader, "zombie.iso.IsoObject");
        door = Game.type(loader, "zombie.iso.objects.IsoDoor");
        Class<?> info = Game.type(loader, "zombie.iso.fboRenderChunk.ObjectRenderInfo");
        Class<?> layers = Game.type(loader, "zombie.iso.fboRenderChunk.ObjectRenderLayer");
        Class<?> anims = Game.type(loader, "zombie.core.skinnedmodel.model.IsoObjectAnimations");
        Class<?> isoSprite = Game.type(loader, "zombie.iso.sprite.IsoSprite");
        Class<?> props = Game.type(loader, "zombie.core.properties.PropertyContainer");
        Class<?> fx = Game.type(loader, "zombie.iso.objects.ObjectRenderEffects");
        Class<?> colourType = Game.type(loader, "zombie.core.textures.ColorInfo");
        Class<?> core = Game.type(loader, "zombie.core.Core");
        Class<?> drawer = Game.type(loader, "zombie.core.skinnedmodel.model.IsoObjectModelDrawer");
        Class<?> spriteModelType = Game.type(loader, "zombie.iso.SpriteModel");
        spriteModel = method(object, "getSpriteModel", OBJ_OBJ);
        renderInfo = method(object, "getRenderInfo", MethodType.methodType(Object.class, Object.class, int.class), int.class);
        sprite = method(object, "getSprite", OBJ_OBJ);
        var floatOf = MethodType.methodType(float.class, Object.class);
        xOf = method(object, "getX", floatOf);
        yOf = method(object, "getY", floatOf);
        zOf = method(object, "getZ", floatOf);
        yOffset = method(object, "getRenderYOffset", floatOf);
        effects = method(object, "getObjectRenderEffectsToApply", OBJ_OBJ);
        colourOf = method(object, "getOutlineHighlightCol", MethodType.methodType(int.class, Object.class, int.class), int.class);
        blinks = method(object, "isOutlineHlBlink", MethodType.methodType(boolean.class, Object.class, int.class), int.class);
        outlined = method(object, "isOutlineHighlight", MethodType.methodType(boolean.class, Object.class, int.class), int.class);
        doubleIndex = method(door, "getDoubleDoorIndex", MethodType.methodType(int.class, Object.class), object);
        doubleObject = method(door, "getDoubleDoorObject", MethodType.methodType(Object.class, Object.class, int.class), object, int.class);
        layer = getter(info, "layer", OBJ_OBJ);
        targetAlpha = getter(info, "targetAlpha", floatOf);
        none = layers.getField("None").get(null);
        animations = method(anims, "getInstance", MethodType.methodType(Object.class));
        animationOf = method(anims, "getAnimationPlayer", MethodType.methodType(Object.class, Object.class, Object.class), object);
        properties = method(isoSprite, "getProperties", OBJ_OBJ);
        surfaceOffset = method(props, "isSurfaceOffset", MethodType.methodType(boolean.class, Object.class));
        surface = method(props, "getSurface", MethodType.methodType(int.class, Object.class));
        var doubleOf = MethodType.methodType(double.class, Object.class);
        shiftX = getter(fx, "x1", doubleOf);
        shiftY = getter(fx, "y1", doubleOf);
        setAbgr = method(colourType, "setABGR", OBJ_OBJ.appendParameterTypes(int.class), int.class);
        setA = LOOKUP.unreflectSetter(colourType.getField("a")).asType(MethodType.methodType(void.class, Object.class, float.class));
        getA = getter(colourType, "a", floatOf);
        getR = getter(colourType, "r", floatOf);
        getG = getter(colourType, "g", floatOf);
        getB = getter(colourType, "b", floatOf);
        blinkAlpha = getter(core, "blinkAlpha", MethodType.methodType(float.class));
        renderMainOutline = method(drawer, "renderMainOutline", MethodType.methodType(Object.class, Object.class, float.class, float.class,
            float.class, Object.class, float.class), spriteModelType, float.class, float.class, float.class, colourType, float.class);
        colour = colourType.getConstructor().newInstance();

        Class<?> slot = Game.type(loader, "zombie.core.skinnedmodel.model.ModelSlotRenderData");
        Class<?> shader = Game.type(loader, "zombie.core.skinnedmodel.shader.Shader");
        Class<?> shaderProgram = Game.type(loader, "zombie.core.opengl.ShaderProgram");
        Class<?> instanceData = Game.type(loader, "zombie.core.skinnedmodel.model.ModelInstanceRenderData");
        Class<?> modelType = Game.type(loader, "zombie.core.skinnedmodel.model.Model");
        Class<?> modelOutlines = Game.type(loader, "zombie.core.skinnedmodel.model.ModelOutlines");
        Class<?> fbo = Game.type(loader, "zombie.core.textures.TextureFBO");
        Class<?> modelCamera = Game.type(loader, "zombie.core.skinnedmodel.ModelCamera");
        Class<?> gl = Game.type(loader, "org.lwjgl.opengl.GL11");
        Class<?> texture = Game.type(loader, "zombie.core.textures.Texture");
        Class<?> spriteRenderer = Game.type(loader, "zombie.core.SpriteRenderer");
        Class<?> ring = Game.type(loader, "zombie.core.SpriteRenderer$RingBuffer");
        Class<?> glState = Game.type(loader, "zombie.core.opengl.GLStateRenderThread");
        Class<?> matrix = Game.type(loader, "org.joml.Matrix4f");
        var staticObject = MethodType.methodType(Object.class);
        var putStatic = MethodType.methodType(void.class, Object.class);
        solid = getter(slot, "solidColor", staticObject);
        solidStatic = getter(slot, "solidColorStatic", staticObject);
        setSolid = LOOKUP.unreflectSetter(slot.getField("solidColor")).asType(putStatic);
        setSolidStatic = LOOKUP.unreflectSetter(slot.getField("solidColorStatic")).asType(putStatic);
        modelData = getter(slot, "modelData", MethodType.methodType(List.class, Object.class));
        newShader = LOOKUP.unreflectConstructor(shader.getConstructor(String.class, boolean.class, boolean.class))
            .asType(MethodType.methodType(Object.class, String.class, boolean.class, boolean.class));
        var run = MethodType.methodType(void.class, Object.class);
        start = method(shader, "Start", run);
        end = method(shader, "End", run);
        program = method(shader, "getShaderProgram", OBJ_OBJ);
        transform = method(shader, "setTransformMatrix", MethodType.methodType(void.class, Object.class, Object.class, boolean.class),
            matrix, boolean.class);
        palette = method(shader, "setMatrixPalette", MethodType.methodType(void.class, Object.class, Object.class, boolean.class),
            java.nio.FloatBuffer.class, boolean.class);
        vector4 = method(shaderProgram, "setVector4", MethodType.methodType(void.class, Object.class, String.class, float.class,
            float.class, float.class, float.class), String.class, float.class, float.class, float.class, float.class);
        model = getter(instanceData, "model", OBJ_OBJ);
        matrixPalette = getter(instanceData, "matrixPalette", OBJ_OBJ);
        renderVehicle = method(instanceData, "RenderVehicle", MethodType.methodType(void.class, Object.class, Object.class), slot);
        effect = getter(modelType, "effect", OBJ_OBJ);
        setEffect = LOOKUP.unreflectSetter(modelType.getField("effect")).asType(MethodType.methodType(void.class, Object.class, Object.class));
        isStatic = getter(modelType, "isStatic", MethodType.methodType(boolean.class, Object.class));
        outlines = getter(modelOutlines, "instance", staticObject);
        begin = method(modelOutlines, "beginRenderOutline", MethodType.methodType(boolean.class, Object.class, Object.class, boolean.class,
            boolean.class), colourType, boolean.class, boolean.class);
        fboA = getter(modelOutlines, "fboA", OBJ_OBJ);
        startDrawing = method(fbo, "startDrawing", MethodType.methodType(void.class, Object.class, boolean.class, boolean.class),
            boolean.class, boolean.class);
        endDrawing = method(fbo, "endDrawing", run);
        camera = getter(modelCamera, "instance", staticObject);
        depthMask = LOOKUP.unreflectSetter(modelCamera.getField("depthMask")).asType(MethodType.methodType(void.class, Object.class, boolean.class));
        var oneInt = MethodType.methodType(void.class, int.class);
        pushClient = method(gl, "glPushClientAttrib", oneInt, int.class);
        pushAttrib = method(gl, "glPushAttrib", oneInt, int.class);
        popAttrib = method(gl, "glPopAttrib", MethodType.methodType(void.class));
        popClient = method(gl, "glPopClientAttrib", MethodType.methodType(void.class));
        enable = method(gl, "glEnable", oneInt, int.class);
        disable = method(gl, "glDisable", oneInt, int.class);
        blendFunc = method(gl, "glBlendFunc", MethodType.methodType(void.class, int.class, int.class), int.class, int.class);
        alphaFunc = method(gl, "glAlphaFunc", MethodType.methodType(void.class, int.class, float.class), int.class, float.class);
        lastTexture = LOOKUP.unreflectSetter(texture.getField("lastTextureID")).asType(MethodType.methodType(void.class, int.class));
        ringBuffer = getter(spriteRenderer, "ringBuffer", staticObject);
        restoreVbos = LOOKUP.unreflectSetter(ring.getField("restoreVbos")).asType(MethodType.methodType(void.class, Object.class, boolean.class));
        restore = method(glState, "restore", MethodType.methodType(void.class));
        identity = matrix.getConstructor().newInstance();
    }

    private static MethodHandle method(Class<?> owner, String name, MethodType as, Class<?>... parameters) throws ReflectiveOperationException {
        return Game.exact(owner.getMethod(name, parameters), as);
    }

    private static MethodHandle getter(Class<?> owner, String name, MethodType as) throws ReflectiveOperationException {
        return LOOKUP.unreflectGetter(owner.getField(name)).asType(as);
    }

    /** Takes the game's hooks. Throws a LinkageError with a bootstrap from before the outlines. */
    void hook() { Hooks.setOutlines(this); }

    /** The hooks draw as the game alone would. */
    static void unhook() {
        try { Hooks.setOutlines(null); } catch (LinkageError olderBootstrap) { }
    }

    @Override
    public boolean model(int player, Object object) throws Throwable {
        Object model = (Object)spriteModel.invokeExact(object);
        if (model == null) return false;
        Object drawn = object;
        if (door.isInstance(object)) {
            int half = (int)doubleIndex.invokeExact(object);
            if (half == 2 || half == 3) {
                Object partner = (Object)doubleObject.invokeExact(object, half == 2 ? 1 : 4);
                Object partnerModel = partner == null ? null : (Object)spriteModel.invokeExact(partner);
                if (partnerModel != null) { drawn = partner; model = partnerModel; }
            }
        }
        Object shown = (Object)renderInfo.invokeExact(drawn, player);
        if ((Object)layer.invokeExact(shown) == none || (float)targetAlpha.invokeExact(shown) <= 0f) return true;
        if ((Object)animationOf.invokeExact((Object)animations.invokeExact(), drawn) != null) return true;
        Object spriteOf = (Object)sprite.invokeExact(drawn);
        float lift = 0f;
        if (spriteOf != null) {
            Object found = (Object)properties.invokeExact(spriteOf);
            if (found != null && (boolean)surfaceOffset.invokeExact(found)) lift = (int)surface.invokeExact(found);
        }
        float x = (float)xOf.invokeExact(drawn) + 0.5f, y = (float)yOf.invokeExact(drawn) + 0.5f, z = (float)zOf.invokeExact(drawn);
        Object shift = (Object)effects.invokeExact(drawn);
        if (shift != null) {
            x += (float)((double)shiftX.invokeExact(shift) * 1.5);
            y += (float)((double)shiftY.invokeExact(shift) * 1.5);
        }
        // its alpha kept (the game's own model outline sets it to 1): a mod's faint outline stays as faint as on a sprite
        Object c = (Object)setAbgr.invokeExact(colour, (int)colourOf.invokeExact(object, player));
        if ((boolean)blinks.invokeExact(object, player)) setA.invokeExact(c, (float)getA.invokeExact(c) * (float)blinkAlpha.invokeExact());
        Object status = (Object)renderMainOutline.invokeExact(model, x, y, z, c, (float)yOffset.invokeExact(drawn) + lift);
        return true;
    }

    /**
     * The pass's objects, those outlined for the player one colour after another (blinking apart), in the order they had
     * otherwise; the rest after them. The game's outline buffer is laid over the frame each time the colour changes, so
     * the squares of one piece of furniture outlined alike, drawn apart, showed their seams. An insertion sort in place: a
     * pass has a few objects, and it allocates nothing.
     */
    @Override
    public void order(int player, Object objects) throws Throwable {
        @SuppressWarnings("unchecked")
        var list = (List<Object>)objects;
        int size = list.size();
        if (size < 3) return;
        for (int index = 1; index < size; index++) {
            Object object = list.get(index);
            long key = key(object, player);
            int at = index - 1;
            while (at >= 0 && key(list.get(at), player) > key) {
                list.set(at + 1, list.get(at));
                at--;
            }
            list.set(at + 1, object);
        }
    }

    // The colour (blinking or not) of an object outlined for the player; the largest for one that is not.
    private long key(Object object, int player) throws Throwable {
        if (!(boolean)outlined.invokeExact(object, player)) return Long.MAX_VALUE;
        long colour = (int)colourOf.invokeExact(object, player) & 0xFFFFFFFFL;
        return (boolean)blinks.invokeExact(object, player) ? colour | 1L << 32 : colour;
    }

    @Override
    public int vehicle(Object vehicle, int player, Object colourInto, float here, float camera) throws Throwable {
        if (!(boolean)outlined.invokeExact(vehicle, player)) return 0;
        Object c = (Object)setAbgr.invokeExact(colourInto, (int)colourOf.invokeExact(vehicle, player));
        if ((boolean)blinks.invokeExact(vehicle, player)) setA.invokeExact(c, (float)getA.invokeExact(c) * (float)blinkAlpha.invokeExact());
        return here < camera ? 3 : 1;
    }

    @Override
    public void drawVehicle(Object data, Object colour, boolean behind) throws Throwable {
        pushClient.invokeExact(-1);
        pushAttrib.invokeExact(1048575);
        try {
            enable.invokeExact(3042);
            blendFunc.invokeExact(770, 771);
            enable.invokeExact(3008);
            alphaFunc.invokeExact(516, 0f);
            enable.invokeExact(2929);
            disable.invokeExact(3089);
            Object plain = (Object)solid.invokeExact(), still = (Object)solidStatic.invokeExact();
            if (plain == null) {
                plain = (Object)newShader.invokeExact("aim_outline_solid", false, false);
                still = (Object)newShader.invokeExact("aim_outline_solid", true, false);
                setSolid.invokeExact(plain);
                setSolidStatic.invokeExact(still);
            }
            float r = (float)getR.invokeExact(colour), g = (float)getG.invokeExact(colour), b = (float)getB.invokeExact(colour);
            for (Object shader : new Object[] { plain, still }) {
                start.invokeExact(shader);
                vector4.invokeExact((Object)program.invokeExact(shader), "u_color", r, g, b, 1f);
                end.invokeExact(shader);
            }
            Object cam = (Object)camera.invokeExact();
            depthMask.invokeExact(cam, false);
            Object buffers = (Object)outlines.invokeExact();
            boolean clear = (boolean)begin.invokeExact(buffers, colour, behind, false);
            Object target = (Object)fboA.invokeExact(buffers);
            startDrawing.invokeExact(target, clear, true);
            try {
                List<?> parts = (List<?>)modelData.invokeExact(data);
                for (int at = 0, count = parts.size(); at < count; at++) {
                    Object part = parts.get(at);
                    Object partModel = (Object)model.invokeExact(part);
                    if (partModel == null) continue;
                    Object saved = (Object)effect.invokeExact(partModel);
                    boolean fixed = (boolean)isStatic.invokeExact(partModel);
                    Object use = fixed ? still : plain;
                    // the solid shaders are not the vehicle's: its draw sets no transform for them (Model.DrawVehicle)
                    start.invokeExact(use);
                    if (fixed) transform.invokeExact(use, identity, false);
                    else {
                        Object bones = (Object)matrixPalette.invokeExact(part);
                        if (bones != null) palette.invokeExact(use, bones, true);
                    }
                    end.invokeExact(use);
                    setEffect.invokeExact(partModel, use);
                    try { renderVehicle.invokeExact(part, data); }
                    finally { setEffect.invokeExact(partModel, saved); }
                }
            } finally {
                endDrawing.invokeExact(target);
                depthMask.invokeExact(cam, true);
            }
        } finally {
            popAttrib.invokeExact();
            popClient.invokeExact();
            lastTexture.invokeExact(-1);
            enable.invokeExact(3553);
            restoreVbos.invokeExact((Object)ringBuffer.invokeExact(), true);
            restore.invokeExact();
        }
    }
}
