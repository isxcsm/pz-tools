package pzext.api;

import java.nio.FloatBuffer;
import org.lwjgl.opengl.GL11;
import zombie.core.Core;
import zombie.core.SpriteRenderer;
import zombie.core.opengl.GLStateRenderThread;
import zombie.core.skinnedmodel.ModelCamera;
import zombie.core.skinnedmodel.ModelManager;
import zombie.core.skinnedmodel.model.IsoObjectAnimations;
import zombie.core.skinnedmodel.model.IsoObjectModelDrawer;
import zombie.core.skinnedmodel.model.Model;
import zombie.core.skinnedmodel.model.ModelInstanceRenderData;
import zombie.core.skinnedmodel.model.ModelOutlines;
import zombie.core.skinnedmodel.model.ModelSlotRenderData;
import zombie.core.skinnedmodel.shader.Shader;
import zombie.core.textures.Texture;
import zombie.core.textures.TextureFBO;
import zombie.iso.IsoMovingObject;
import zombie.iso.IsoObject;
import zombie.iso.SpriteModel;
import zombie.iso.fboRenderChunk.FBORenderObjectOutline;
import zombie.iso.fboRenderChunk.ObjectRenderLayer;
import zombie.iso.objects.IsoDoor;
import zombie.iso.objects.ObjectRenderEffects;
import zombie.iso.sprite.IsoSprite;
import zombie.vehicles.BaseVehicle;

/**
 * The game's outline on what it leaves out (docs/design.md, "Outlines"), against the synthetic game: an outlined
 * object drawn as a model gets the game's model outline where its model is drawn, in its colour, and the sprite pass skips it;
 * a sprite object still gets the sprite pass; a double door's far halves are drawn with their partner's model; nothing while the
 * object is not shown or its model animates. A vehicle outlined takes a character's outline: on, its colour, behind or not, and
 * its models drawn into the outline buffer with the solid shaders, every state put back.
 */
final class OutlinesTest {
    // 0xAABBGGRR, as IsoObject.setOutlineHighlightCol packs it: red 0.8, green 0.4, blue 0.2, alpha 0.6.
    private static final int MUTED = 153 << 24 | 51 << 16 | 102 << 8 | 204;

    private OutlinesTest() { }

    static void run() {
        models();
        doubleDoors();
        hidden();
        vehicles();
        vehicleDrawing();
    }

    private static IsoObject outlined(IsoObject object) {
        object.outlined[0] = true;
        object.outlineCol[0] = MUTED;
        return object;
    }

    private static void models() {
        var outline = FBORenderObjectOutline.instance;
        IsoObjectModelDrawer.outlines.clear();
        int sprites = outline.sprites;
        var window = outlined(new IsoObject(new IsoSprite("window")));
        outline.render(0, window);
        check(outline.sprites == sprites + 1 && IsoObjectModelDrawer.outlines.isEmpty(), "A sprite object did not keep the game's sprite outline");

        var model = new SpriteModel();
        var sprite = new IsoSprite("door");
        sprite.properties.surface = 12;
        var door = (IsoDoor)outlined(new IsoDoor(sprite));
        door.spriteModel = model;
        door.placedX = 10; door.placedY = 20; door.placedZ = 1; door.renderYOffset = 3;
        door.renderEffects = new ObjectRenderEffects();
        door.renderEffects.x1 = 0.1; door.renderEffects.y1 = -0.2;
        outline.render(0, door);
        check(outline.sprites == sprites + 1, "A model door went through the sprite outline too");
        check(IsoObjectModelDrawer.outlines.size() == 1, "A model door got no model outline");
        Object[] drawn = IsoObjectModelDrawer.outlines.get(0);
        check(drawn[0] == model && near(drawn[1], 10.65f) && near(drawn[2], 20.2f) && near(drawn[3], 1f) && near(drawn[8], 15f),
            "The model outline is not where the model is drawn: " + java.util.Arrays.toString(drawn));
        check(near(drawn[4], 0.8f) && near(drawn[5], 0.4f) && near(drawn[6], 0.2f) && near(drawn[7], 0.6f),
            "The model outline is not in the object's colour: " + java.util.Arrays.toString(drawn));

        door.outlineBlink[0] = true;
        Core.blinkAlpha = 0.25f;
        try { outline.render(0, door); }
        finally { Core.blinkAlpha = 1f; }
        check(near(IsoObjectModelDrawer.outlines.get(1)[7], 0.15f), "A blinking outline does not blink");
        IsoObjectModelDrawer.outlines.clear();
    }

    private static void doubleDoors() {
        var outline = FBORenderObjectOutline.instance;
        var model = new SpriteModel();
        var first = new IsoDoor(new IsoSprite("double 1"));
        first.spriteModel = model;
        first.placedX = 5; first.placedY = 6;
        var second = (IsoDoor)outlined(new IsoDoor(new IsoSprite("double 2")));
        second.spriteModel = new SpriteModel();
        second.placedX = 5; second.placedY = 7;
        second.doubleIndex = 2;
        second.halves[1] = first;
        outline.render(0, second);
        Object[] drawn = IsoObjectModelDrawer.outlines.get(0);
        check(drawn[0] == model && near(drawn[2], 6.5f), "A double door's second half was not drawn with its first half's model");
        check(near(drawn[4], 0.8f), "A double door's half lost its own outline colour");
        IsoObjectModelDrawer.outlines.clear();
    }

    private static void hidden() {
        var outline = FBORenderObjectOutline.instance;
        int sprites = outline.sprites;
        var door = outlined(new IsoDoor(new IsoSprite("door")));
        door.spriteModel = new SpriteModel();
        door.renderInfo[0].layer = ObjectRenderLayer.None;
        outline.render(0, door);
        door.renderInfo[0].layer = ObjectRenderLayer.Opaque;
        door.renderInfo[0].targetAlpha = 0f;
        outline.render(0, door);
        door.renderInfo[0].targetAlpha = 1f;
        IsoObjectAnimations.getInstance().animating.add(door);
        try { outline.render(0, door); }
        finally { IsoObjectAnimations.getInstance().animating.remove(door); }
        check(IsoObjectModelDrawer.outlines.isEmpty() && outline.sprites == sprites,
            "A model object not shown, or animating, was outlined");

        // A fault leaves the game's pass to itself.
        door.renderInfo[0] = null;
        outline.render(0, door);
        check(outline.sprites == sprites + 1, "A fault in the model outline kept the game's pass from the object");
    }

    private static ModelSlotRenderData slot(IsoMovingObject object, float x, float camera) {
        var slot = new ModelManager.ModelSlot();
        slot.object = object;
        slot.x = x; slot.y = 0; slot.cameraX = camera; slot.cameraY = 0;
        var data = new ModelSlotRenderData();
        data.initModel(slot);
        return data;
    }

    private static void vehicles() {
        var car = new BaseVehicle();
        check(!slot(car, 5, 3).outlined(), "A vehicle not outlined took an outline");
        outlined(car);
        var front = slot(car, 5, 3);
        check(front.outlined() && !front.behind(), "An outlined vehicle in front of the character took no outline");
        var colour = front.outlineColour();
        check(near(colour.r, 0.8f) && near(colour.g, 0.4f) && near(colour.b, 0.2f) && near(colour.a, 0.6f),
            "The vehicle's outline is not in its colour");
        check(slot(car, 1, 3).behind(), "A vehicle behind the character is not drawn as behind");
        car.outlineBlink[0] = true;
        Core.blinkAlpha = 0.5f;
        try { check(near(slot(car, 5, 3).outlineColour().a, 0.3f), "A blinking vehicle outline does not blink"); }
        finally { Core.blinkAlpha = 1f; car.outlineBlink[0] = false; }
        var walker = outlined(new IsoMovingObject());
        check(!slot((IsoMovingObject)walker, 5, 3).outlined(), "Another moving object took a vehicle's outline");
    }

    private static void vehicleDrawing() {
        var car = (BaseVehicle)outlined(new BaseVehicle());
        var data = slot(car, 5, 3);
        var body = new Model();
        var own = new Shader("vehicle", false, false);
        body.effect = own;
        var wheel = new Model();
        wheel.isStatic = true;
        var wheelShader = new Shader("vehicle wheel", true, false);
        wheel.effect = wheelShader;
        var bodyPart = new ModelInstanceRenderData();
        bodyPart.model = body;
        bodyPart.matrixPalette = FloatBuffer.allocate(16);
        var wheelPart = new ModelInstanceRenderData();
        wheelPart.model = wheel;
        data.modelData.add(bodyPart);
        data.modelData.add(wheelPart);
        var buffers = ModelOutlines.instance;
        TextureFBO previous = buffers.fboA;
        buffers.fboA = new TextureFBO(new Texture("outline", 64, 64));
        ModelInstanceRenderData.drawn.clear();
        int restores = GLStateRenderThread.restores, begun = buffers.begun, pushed = GL11.pushed;
        Texture.lastTextureID = 7;
        SpriteRenderer.ringBuffer.restoreVbos = false;
        try {
            data.render();
            check(data.vehicleDraws == 1, "The vehicle itself was not drawn");
            check(buffers.begun == begun + 1 && ModelInstanceRenderData.drawn.size() == 2, "The vehicle was not drawn into the outline buffer");
            Shader solid = ModelSlotRenderData.solidColor, still = ModelSlotRenderData.solidColorStatic;
            check(solid != null && still != null && "aim_outline_solid".equals(solid.name) && still.isStatic,
                "The game's solid shaders were not made");
            check(ModelInstanceRenderData.drawn.get(0) == solid && ModelInstanceRenderData.drawn.get(1) == still,
                "The vehicle's models were not drawn with the solid shaders");
            check(solid.palette == bodyPart.matrixPalette && still.transform != null, "The solid shaders did not take the models' placing");
            check(near(solid.getShaderProgram().colour[0], 0.8f) && near(still.getShaderProgram().colour[2], 0.2f)
                && near(solid.getShaderProgram().colour[3], 1f), "The solid shaders are not in the outline's colour");
            check(body.effect == own && wheel.effect == wheelShader, "The models' own shaders were not put back");
            check(GL11.pushed == pushed && TextureFBO.drawing == null && ModelCamera.instance.depthMask
                && GLStateRenderThread.restores == restores + 1 && Texture.lastTextureID == -1 && SpriteRenderer.ringBuffer.restoreVbos,
                "The outline pass did not put the drawing state back");
            check(!buffers.behind, "A vehicle in front was drawn as behind");

            data.renderToTexture = true;
            data.render();
            check(buffers.begun == begun + 1, "A vehicle drawn to a texture (its preview) was outlined");
            data.renderToTexture = false;
            car.outlined[0] = false;
            var plain = slot(car, 5, 3);
            plain.render();
            check(buffers.begun == begun + 1 && plain.vehicleDraws == 1, "A vehicle no longer outlined was outlined");
        } finally {
            buffers.fboA = previous;
            ModelSlotRenderData.solidColor = null;
            ModelSlotRenderData.solidColorStatic = null;
            ModelInstanceRenderData.drawn.clear();
        }
    }

    private static boolean near(Object value, float expected) { return Math.abs(((Number)value).floatValue() - expected) < 1e-4f; }

    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
