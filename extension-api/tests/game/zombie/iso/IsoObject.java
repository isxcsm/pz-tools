package zombie.iso;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.function.Consumer;
import se.krka.kahlua.vm.KahluaTable;
import zombie.Lua.LuaManager;
import zombie.core.opengl.Shader;
import zombie.core.textures.ColorInfo;
import zombie.core.textures.TextureDraw;
import zombie.entity.components.fluids.Fluid;
import zombie.entity.components.fluids.FluidContainer;
import zombie.entity.components.fluids.FluidSample;
import zombie.inventory.ItemContainer;
import zombie.iso.sprite.IsoSprite;
import zombie.iso.sprite.IsoSpriteInstance;

/**
 * Synthetic: what the game says about an object's power use comes from the object. Its water questions branch on
 * {@code usesExternalWaterSource} as the game's do: a piped fixture answers with its source's water. A fixture of the
 * map ({@code unmoved}) without a container keeps water of its own, its reserve, as the game's sinks do.
 */
public class IsoObject {
    public IsoSprite sprite;
    /** Where the sprite is drawn, moved from the square's place (a floor's are what its decals are drawn with). */
    public float offsetX, offsetY;
    public IsoGridSquare square;
    public boolean powered;
    public float consumption;
    public int electricityChecks;
    /** The other parts of an object that covers several squares. */
    public final ArrayList<IsoObject> gridParts = new ArrayList<>();
    public boolean usesExternalWaterSource;
    public IsoObject externalWaterSource;
    /** A piped fixture in a room the game's mains reach (its sprite, room and zone checks in one): a test sets it. */
    public boolean mainsPiped;
    public FluidContainer fluidContainer;
    /** A fixture of the map, its reserve (litres, and most), and whether the game has its water tainted (its sprite). */
    public boolean unmoved, taintedFlag;
    public float reserve, reserveMax;
    public KahluaTable modData;
    /** The animations attached to the object, drawn over it; null for none. */
    public ArrayList<IsoSpriteInstance> attachedAnimSprite;
    /** An animation of the object's own plays (a door opening): the chunk renderer draws it every frame. */
    public boolean animating;
    private final ColorInfo light = new ColorInfo();
    public int syncs;
    /** The alpha the object fades to, for each local player, and how many times it was set. */
    public final float[] targetAlpha = { 1f, 1f, 1f, 1f };
    public int alphaSets;
    public IsoObject(IsoSprite sprite) { this.sprite = sprite; }
    public void setTargetAlpha(int player, float alpha) { targetAlpha[player] = alpha; alphaSets++; }
    public float getTargetAlpha(int player) { return targetAlpha[player]; }
    /** The alpha each player sees it at, which the game fades towards the target. */
    public final float[] alpha = { 0f, 0f, 0f, 0f };
    public float getAlpha(int player) { return alpha[player]; }
    public void setAlpha(int player, float value) { alpha[player] = value; }
    public IsoSprite getSprite() { return sprite; }
    // The outline (per player), the model it is drawn as, where it is drawn, its render state.
    public final boolean[] outlined = new boolean[4], outlineBlink = new boolean[4];
    public final int[] outlineCol = new int[4];
    public zombie.iso.SpriteModel spriteModel;
    public float placedX, placedY, placedZ, renderYOffset;
    public zombie.iso.objects.ObjectRenderEffects renderEffects;
    public final zombie.iso.fboRenderChunk.ObjectRenderInfo[] renderInfo = {
        new zombie.iso.fboRenderChunk.ObjectRenderInfo(), new zombie.iso.fboRenderChunk.ObjectRenderInfo(),
        new zombie.iso.fboRenderChunk.ObjectRenderInfo(), new zombie.iso.fboRenderChunk.ObjectRenderInfo() };
    public boolean isOutlineHighlight(int player) { return outlined[player]; }
    public boolean isOutlineHlBlink(int player) { return outlineBlink[player]; }
    public final int getOutlineHighlightCol(int player) { return outlineCol[player]; }
    public zombie.iso.SpriteModel getSpriteModel() { return spriteModel; }
    public zombie.iso.fboRenderChunk.ObjectRenderInfo getRenderInfo(int player) { return renderInfo[player]; }
    public float getX() { return placedX; }
    public float getY() { return placedY; }
    public float getZ() { return placedZ; }
    public float getRenderYOffset() { return renderYOffset; }
    public zombie.iso.objects.ObjectRenderEffects getObjectRenderEffectsToApply() { return renderEffects; }
    public String getSpriteName() { return null; }
    public IsoGridSquare getSquare() { return square; }
    public boolean couldBePoweredByGenerator() { return powered; }
    public float getGeneratorPowerConsumption() { return consumption; }
    public void checkHaveElectricity() { electricityChecks++; }
    public FluidContainer getFluidContainer() { return fluidContainer; }
    public boolean getUsesExternalWaterSource() { return usesExternalWaterSource; }

    /** Like the game's: the mains give a fixture of theirs water while they run, unless it takes it from elsewhere. */
    private boolean isWaterInfinite() {
        return mainsPiped && !getUsesExternalWaterSource()
            && zombie.GameTime.getInstance().getWorldAgeDaysSinceBegin() < zombie.SandboxOptions.instance.getWaterShutModifier();
    }

    private IsoObject checkExternalFluidSource() {
        if (!usesExternalWaterSource) return null;
        return externalWaterSource;
    }

    // The game's reserve, private as there.
    private boolean isUnmovedPipedWaterSource() { return unmoved; }
    private float getReserveWaterAmount() { return reserve; }
    private float getReserveWaterMax() { return reserveMax; }
    private void setReserveWaterAmount(float litres) { reserve = Math.max(0, Math.min(litres, reserveMax)); }

    /** Like the game's: its container while that holds some, else its reserve. */
    private boolean ownContainer() { return fluidContainer != null && fluidContainer.getAmount() > 0; }

    public float getFluidAmount() {
        if (isWaterInfinite()) return 10000;
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            return source == null ? 0 : source.getFluidAmount();
        }
        if (ownContainer()) return fluidContainer.getAmount();
        if (isUnmovedPipedWaterSource()) return getReserveWaterAmount();
        return 0;
    }

    public float getFluidCapacity() {
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            return source == null ? 0 : source.getFluidCapacity();
        }
        if (fluidContainer != null) return fluidContainer.getCapacity();
        return isUnmovedPipedWaterSource() ? getReserveWaterMax() : 0;
    }

    public float useFluid(float amount) {
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            return source == null ? 0 : source.useFluid(amount);
        }
        if (ownContainer()) {
            float used = Math.min(amount, fluidContainer.getAmount());
            fluidContainer.removeFluid(used);
            return used;
        }
        if (!isUnmovedPipedWaterSource()) return 0;
        float used = Math.min(amount, getReserveWaterAmount());
        setReserveWaterAmount(getReserveWaterAmount() - used);
        return used;
    }

    /**
     * Like the game's: a piped fixture's water comes through a sample of its source, purified; from a source without a
     * container, as that source gives it. A fixture's reserve gives its own water.
     */
    public float transferFluidTo(FluidContainer target, float amount) {
        if (isWaterInfinite()) {
            float used = Math.max(0, Math.min(amount, target.getFreeCapacity()));
            target.addFluid(Fluid.Water, used);
            return used;
        }
        if (!usesExternalWaterSource) {
            if (ownContainer() || !isUnmovedPipedWaterSource()) return 0;
            float used = Math.max(0, Math.min(amount, Math.min(target.getFreeCapacity(), getReserveWaterAmount())));
            target.addFluid(taintedFlag ? Fluid.TaintedWater : Fluid.Water, used);
            setReserveWaterAmount(getReserveWaterAmount() - used);
            return used;
        }
        IsoObject source = checkExternalFluidSource();
        if (source == null) return 0;
        if (source.fluidContainer == null) return source.transferFluidTo(target, amount);
        float used = Math.max(0, Math.min(amount, Math.min(target.getFreeCapacity(), source.getFluidAmount())));
        FluidContainer sample = createSampleAndPurifyWater(source.fluidContainer, used);
        FluidSample fluids = sample.createFluidSample();
        for (int index = 0; index < fluids.size(); index++) target.addFluid(fluids.getFluid(index), fluids.getFluidInstance(index).getAmount());
        source.fluidContainer.removeFluid(used);
        return used;
    }

    // Reassigns its argument, as the game's does.
    private FluidContainer createSampleAndPurifyWater(FluidContainer source, float amount) {
        FluidContainer sample = FluidContainer.CreateContainer();
        if (source != null) {
            amount = Math.max(0, Math.min(amount, source.getAmount()));
            FluidSample fluids = source.createFluidSample(1);
            for (int index = 0; index < fluids.size(); index++) {
                Fluid fluid = fluids.getFluid(index) == Fluid.TaintedWater ? Fluid.Water : fluids.getFluid(index);
                sample.addFluid(fluid, amount * fluids.getFluidInstance(index).getAmount());
            }
        }
        return sample;
    }

    /** Like the game's: a piped fixture's water is clean while its source holds some. */
    public boolean isTaintedWater() {
        if (usesExternalWaterSource) {
            IsoObject source = checkExternalFluidSource();
            if (source == null) return false;
            if (source.fluidContainer != null && source.fluidContainer.getAmount() > 0) return false;
            return source.isTaintedWater();
        }
        if (ownContainer()) return fluidContainer.isTainted();
        return isUnmovedPipedWaterSource() && taintedFlag;
    }

    /** The containers the object holds (shelves, a counter's drawers), in the order the game lists them. */
    public final ArrayList<ItemContainer> containers = new ArrayList<>();
    public int getContainerCount() { return containers.size(); }
    public ItemContainer getContainerByIndex(int index) { return index >= 0 && index < containers.size() ? containers.get(index) : null; }

    public boolean hasModData() { return modData != null; }
    public KahluaTable getModData() {
        if (modData == null) modData = LuaManager.platform.newTable();
        return modData;
    }

    /** Like the game's AttachExistingAnim, without the offsets and the tint: the instance drawn over the object. */
    public IsoSpriteInstance attachAnim(IsoSprite sprite) {
        if (attachedAnimSprite == null) attachedAnimSprite = new ArrayList<>();
        var instance = new IsoSpriteInstance(sprite);
        attachedAnimSprite.add(instance);
        return instance;
    }

    public boolean hasAttachedAnimSprites() { return attachedAnimSprite != null && !attachedAnimSprite.isEmpty(); }
    public boolean isAnimating() { return animating; }

    /** The game draws the object (the render path, once for each player's screen). */
    public void render() { renderAttachedSprites(IsoDirections.N, 0f, 0f, 0f, light, false, null, null); }

    // Like the game's: each attached animation is drawn, and its update() called after, which does nothing.
    private void renderAttachedSprites(IsoDirections dir, float x, float y, float z, ColorInfo color, boolean wallLighting, Shader shader,
            Consumer<TextureDraw> draws) {
        if (attachedAnimSprite == null) return;
        int count = attachedAnimSprite.size();
        for (int index = 0; index < count; index++) {
            IsoSpriteInstance instance = attachedAnimSprite.get(index);
            instance.update();
        }
    }

    /** The game sends the object to multiplayer clients. */
    public void sync() { syncs++; }

    /** What the world keeps: the game's own flag. */
    public void save(ByteBuffer output, boolean network) { output.put((byte)(usesExternalWaterSource ? 1 : 0)); }

    public boolean hasSpriteGrid() { return !gridParts.isEmpty(); }
    public ArrayList<IsoObject> getSpriteGridObjectsIncludingSelf(ArrayList<IsoObject> result) {
        result.clear();
        result.add(this);
        result.addAll(gridParts);
        return result;
    }
}
