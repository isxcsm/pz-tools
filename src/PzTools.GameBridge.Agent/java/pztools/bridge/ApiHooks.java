package pztools.bridge;

import java.lang.classfile.*;
import java.lang.classfile.instruction.ConstantInstruction;
import java.lang.classfile.instruction.FieldInstruction;
import java.lang.classfile.instruction.OperatorInstruction;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.classfile.instruction.LineNumber;
import java.lang.classfile.instruction.LoadInstruction;
import java.lang.classfile.instruction.ReturnInstruction;
import java.lang.classfile.instruction.StoreInstruction;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.lang.reflect.AccessFlag;
import java.lang.reflect.Method;
import java.security.ProtectionDomain;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BiConsumer;
import java.util.function.Predicate;

/**
 * The stable calls that the extension API's hooks put into game code (docs/design/extension-api.md). The payload that
 * runs the API sets the handlers, and a newer payload replaces them. Without a handler, and when a hook or a handler
 * fails, the game goes on as it would without the hook: the API never fails closed.
 */
public final class ApiHooks {
    /** Set by the payload. Called on the game's own thread. */
    public interface Handler {
        /** The game has made a new Lua environment ({@code LuaManager.init()}); mods load right after this. */
        void luaStarted(Class<?> luaManager) throws Exception;
    }

    /**
     * Set by the payload: the power networks. The square and object questions come on whatever thread the game asks
     * them on, tens of thousands of times a second; the generator calls on the game's thread.
     */
    public interface Power {
        /** Whether a network gives the square electricity. Asked only when the game says it has none. */
        boolean square(int x, int y, int z);

        /**
         * An object's power: an appliance ({@code ItemContainer.isObjectPowered}), a light switch's
         * ({@code IsoLightSwitch.hasElectricityAround}), a radio's or television's ({@code DeviceData.canBePoweredHere}),
         * the power a room's light gets from one of the room's switches (the switch's square, in
         * {@code LightingJNI.checkLights}), or the power that keeps food in a container cold (the container's square, in
         * {@code Food.updateAge}). {@code vanilla} is the game's answer, {@code generators} false when the game asks
         * about the grid alone.
         */
        boolean object(boolean vanilla, Object object, int kind, boolean generators);

        /** {@code IsoGenerator.setSurroundingElectricity()}: true when the API did it instead, for a generator in a network. */
        boolean generator(Object generator);

        /** {@code IsoGenerator.updateGenerator(square)}: something that uses power was switched, placed or taken there. */
        void consumerChanged(Object square);

        /** {@code IsoGenerator.update()}, before the game burns the hours since the generator last did. */
        default void generatorUpdate(Object generator) { }

        /**
         * {@code Food.updateAge}: the hours the food ages over since it last aged, chilled hours counted at the fridge
         * factor. {@code vanilla} is the game's, which counts every hour as the container has power now.
         */
        default double foodHours(double vanilla, Object food) { return vanilla; }
    }

    /** Set by the payload: the water networks. Asked on the thread that uses the fixture. */
    public interface Water {
        /**
         * Whether a fixture takes its water from another object ({@code IsoObject.usesExternalWaterSource}, as the game's
         * water questions read it): {@code vanilla}, or a water network supplies the fixture now.
         */
        boolean plumbed(boolean vanilla, Object fixture);

        /** The object the fixture takes its water from ({@code IsoObject.checkExternalFluidSource()}): {@code vanilla}, or the network's. */
        Object source(Object vanilla, Object fixture);

        /**
         * The sample a fixture's water comes through from its source container
         * ({@code IsoObject.createSampleAndPurifyWater}, which turns TaintedWater into Water): null for the game's, or
         * one in its place.
         */
        default Object sample(Object fixture, Object source, float amount) { return null; }

        /** Whether the fixture's water is tainted ({@code IsoObject.isTaintedWater()}): {@code vanilla}, or more. */
        default boolean tainted(boolean vanilla, Object fixture) { return vanilla; }
    }

    /**
     * Set by the payload: the formulas mods declare (docs/design/extension-api.md, "Formulas"). Every call is for one
     * hook site of a game method and gets the game's own answer; what it returns replaces the answer. Only the local
     * player's character is changed, and a call that has nothing declared returns the game's answer at once. The calls
     * come on the game's thread, some of them many times a frame; none allocates.
     */
    public interface Formulas {
        /** {@code IsoGameCharacter.getClothingDiscomfortModifier()}. */
        default float discomfort(float vanilla, Object character) { return vanilla; }

        /** {@code IsoGameCharacter.addStiffness(part, amount)}: the amount added. */
        default float stiffness(float amount, Object character) { return amount; }

        /** {@code IsoGameCharacter.getFatiqueMultiplier()}. */
        default double fatigue(double vanilla, Object character) { return vanilla; }

        /** {@code Stats.add(stat, delta)} (also {@code remove}): the change to the stat. */
        default float statDelta(float delta, Object stats, Object stat) { return delta; }

        /**
         * {@code IsoGameCharacter.getInventoryWeight()}: how heavy the character's inventory is as the load's formulas
         * count it, or NaN to leave the game's own answer. Asked for any character, at the start of the method.
         */
        default float inventoryWeight(Object character) { return Float.NaN; }

        /** An item went into a tracked list (after the list took it). Called with the API's lock free, on any thread. */
        default void itemAdded(Tracked list, Object item) { }

        /** An item came out of a tracked list (after it did). */
        default void itemRemoved(Tracked list, Object item) { }

        /** A tracked list was emptied. */
        default void listCleared(Tracked list) { }

        /** A tracked list changed in a way that is not followed item by item. */
        default void listChanged(Tracked list) { }

        /** {@code ItemContainer.items} is about to be replaced by another list ({@code setItems}, {@code emptyIt}). */
        default void itemsReplacing(Object container) { }

        /**
         * A field that the weight of an item reads was written (or, for a weapon, its parts changed): the item may weigh
         * something else now. Called in the middle of the game's own method, so it must only note it.
         */
        default void weightChanged(Object item) { }

        /** A fluid container's amount (which the weight of what holds it reads) may have changed. */
        default void fluidChanged(Object fluid) { }

        /**
         * The weight an item adds to a container when {@code ItemContainer.hasRoomFor(character, item)} asks whether
         * it fits. {@code viaBag} when the container is a worn bag and it is the carrying character's inventory the
         * item is weighed against.
         */
        default float incoming(Object item, float vanilla, Object container, boolean viaBag) { return vanilla; }

        /** {@code IsoGameCharacter.getMaxWeight()}. */
        default int maxWeight(int vanilla, Object character) { return vanilla; }

        /** {@code ItemContainer.getEffectiveCapacity(character)}. */
        default int effectiveCapacity(int vanilla, Object container, Object character) { return vanilla; }

        /** {@code ItemContainer.getCapacity()}, which the game clamps to 100, or 50 for an item's, or 1000 for a vehicle's. */
        default int capacity(int vanilla, Object container) { return vanilla; }

        /** {@code InventoryContainer.getCapacity()}, which the game clamps to what a bag can be. */
        default int bagCapacity(int vanilla, Object bag) { return vanilla; }

        /** {@code InventoryContainer.getEffectiveCapacity(character)}. */
        default int bagEffectiveCapacity(int vanilla, Object bag, Object character) { return vanilla; }

        /** What {@code container.getCapacityWeight()} gives to a question of how heavily its character is loaded. */
        default float overload(Object container, float weight) { return weight; }

        /** The full speed modifier {@code IsoGameCharacter.calculateBaseSpeed()} works out (below 1 slows). */
        default float runPenalty(float vanilla, Object character) { return vanilla; }

        /** The combat speed modifier {@code IsoGameCharacter.calculateCombatSpeed()} reads (below 1 slows). */
        default float combatPenalty(float vanilla, Object character) { return vanilla; }

        /** {@code ItemPickerJava.getActualSpawnChance(...)}: the chance an item is put into a container or a corpse. */
        default float lootChance(float vanilla) { return vanilla; }

        /** The ammunition loot modifier {@code ItemPickerJava.getLootModifierFromType("Ammo")} gives. */
        default float lootAmmo(float vanilla) { return vanilla; }

        /** {@code LightingJNI.getLumaInverted(character)}: how dark it is for the character, from 0 (light) to 1. */
        default float darkness(float vanilla, Object character) { return vanilla; }

        /**
         * What {@code LightingJNI.getSquareLighting} handed for a player's square at x, y on floor z (the visibility, the
         * light, two darknesses, the level, then the corner lights), before the game reads it; changed in place. On
         * whatever thread reads the lighting.
         */
        default void squareLit(int playerIndex, int x, int y, int z, int[] lit) { }

        /**
         * Whether a player's square at x, y on floor z, which the lighting says has not changed, is to be read again all
         * the same (what was done to it as it was last read is out of date). On whatever thread reads the lighting.
         */
        default boolean squareStale(int playerIndex, int x, int y, int z) { return false; }

        /** The light {@code FBORenderCell.sanitizeLightInfo} has the game draw a square's objects with, for a player; the light to use. */
        default Object objectLight(Object info, int playerIndex) { return info; }

        /** Once a frame for each player's screen, on the main thread before it is drawn: night sight moves on. */
        default void nightSightFrame(int playerIndex) { }

        /** When the screen pass compiles (with night sight's step or without): its program. */
        default void nightSightProgram(int program) { }

        /** Each time the screen pass draws, on the render thread with its program bound: night sight's uniforms are set. */
        default void nightSightDraw(int program) { }

        /** The vision cone's width in degrees before {@code LightingJNI.calculateVisionCone} applies the worn items'; the width to use. */
        default float coneAdd(Object character, float degrees) { return degrees; }

        /** The speed {@code IsoGameCharacter.DoLand(speed)} lands with. */
        default float landing(float speed, Object character) { return speed; }

        /** The speed {@code FallDamage.getImpactIsoSpeed()} gives {@code handleLandingImpact} for the damage. */
        default float impact(float speed, Object character) { return speed; }

        /** {@code IsoTree.getSlowFactor(mover)}. */
        default float treeSlow(float vanilla, Object mover) { return vanilla; }

        /** {@code IsoPlayer.calculateInTreesSpeed()}: the speed scale of the animation of walking through trees. */
        default float treeAnimation(float vanilla, Object player) { return vanilla; }

        /** Whether {@code IsoGameCharacter.damageWhileInTrees()} goes on to scratch the character this time. */
        default boolean treeScratch(Object character) { return true; }

        /** What the movement {@code IsoPlayer.getDeferredMovement} gives is multiplied by (1 for none). */
        default float walk(Object character) { return 1f; }

        /** {@code Thermoregulator.getCatchAColdDelta()} of the player's thermoregulator. */
        default float cold(float vanilla, Object player) { return vanilla; }

        /** {@code CorpseCount.getCorpseCount(character)}. */
        default int corpseCount(int vanilla, Object character) { return vanilla; }

        /** {@code BodyDamage.GetBaseCorpseSickness()} of the character's body damage. */
        default float corpseSickness(float vanilla, Object character) { return vanilla; }

        /** Whether {@code IsoGameCharacter.addHole(part, boolean)} makes a hole in the clothing this time. */
        default boolean hole(Object character) { return true; }

        /** Whether {@code BodyPart.generateZombieInfection(chance)} rolls for an infection this time. */
        default boolean wound(Object character) { return true; }

        /**
         * A zombie's bite is put on the body part {@code index} of {@code bodyDamage}: just before ({@code after} false) and
         * just after ({@code after} true) {@code BodyDamage.SetBitten(index, true)}, in {@code AddRandomDamageFromZombie}.
         */
        default void bite(Object bodyDamage, int index, boolean after) { }

        /** {@code IsoObject.couldBePoweredByGenerator()}: {@code vanilla}, or true for a machine a mod declared. */
        default boolean machine(boolean vanilla, Object object) { return vanilla; }

        /** {@code IsoObject.getGeneratorPowerConsumption()}: {@code vanilla}, or a declared machine's consumption times its own load. */
        default float machineLoad(float vanilla, Object object) { return vanilla; }

        /**
         * {@code IsoObject.renderAttachedSprites}: an animation attached to {@code object} was drawn, and the game called its
         * {@code IsoSpriteInstance.update()}, which does nothing. The instance is stepped here when a mod declared it.
         */
        default void attachedAnim(Object instance, Object object) { }

        /**
         * {@code IsoObject.isAnimating()}, which the chunk renderer asks as it sorts an object into a layer: {@code vanilla}, or true
         * for an object whose attached animations are stepped, so that it is drawn every frame instead of into the chunk's texture.
         */
        default boolean animating(boolean vanilla, Object object) { return vanilla; }
    }

    /**
     * Set by the payload: the moodles mods define (docs/design/extension-api.md, "Moodles"). Every call gets a moodle type the
     * game asks about and answers for the API's own types alone; any other type gets the game's answer. The calls come on the
     * game's thread, the level once a tick for every moodle of every player; none allocates.
     */
    public interface Moodles {
        /** {@code Moodle.Update()}: the level a moodle of this type of this character is to have, or -1 for the game's own update. */
        default int level(Object type, Object character) { return -1; }

        /** {@code Moodles.GoodBadNeutral(type)}: 0 neutral, 1 good, 2 bad; {@code vanilla} for a type that is not the API's. */
        default int kind(int vanilla, Object type) { return vanilla; }

        /**
         * {@code MoodlesUI.render}: the picture of a type the game's {@code MoodleTextureSet} has none for, at that set's size, for
         * the moodle column {@code ui}; null when the type is not the API's.
         */
        default Object picture(Object set, Object type, Object ui) { return null; }
    }

    /**
     * Set by the payload: the text mods show on the screen (docs/design/extension-api.md, "Text"). Called once each time the game
     * draws its interface ({@code UIManager.render}, on the main thread), after the interface's windows and before the tooltip,
     * the paused message and the fade drawn over the interface. With nothing shown it returns at once.
     */
    public interface Text {
        /** Draws what is shown now. */
        void draw();
    }

    /**
     * Set by the payload while a mod listens for the sounds zombies make (docs/design/extension-api.md, "Zombie sounds"): the
     * moments the game hands a zombie's voice to FMOD alone, which Lua never hears of. Null while nobody listens, so that a hook
     * costs one volatile read. The calls come on the thread that updates the zombies (the game's, or the world's worker when the
     * game threads the world), must not allocate, and only note the moment: the event is raised later, on the game's thread.
     */
    public interface ZombieSounds {
        /**
         * {@code ParameterZombieState.setState(to)} changes the state the zombie's voice is played in (the game returns early when
         * it is the same): {@code from} and {@code to} are {@code ParameterZombieState$State} constants.
         */
        default void state(Object zombie, Object from, Object to) { }

        /** {@code ZombieVocalsManager$Slot.playSound}: the zombie's voice is started ({@code BaseCharacterSoundEmitter.playVocals}). */
        default void voice(Object zombie) { }

        /** {@code IsoZombie.handleLandingImpact}: the zombie lands from a fall. */
        default void landed(Object zombie) { }
    }

    /** The kinds of {@link Power#object}. */
    public static final int APPLIANCE = 0, LIGHT_SWITCH = 1, DEVICE = 2, ROOM_LIGHT = 3, FOOD = 4;

    // The payload loads beside the game's start; the first Lua environment may be made before it is ready.
    private static final long HANDLER_WAIT_NANOS = TimeUnit.SECONDS.toNanos(10);
    private static final ClassDesc HOOKS = ClassDesc.of("pztools.bridge.ApiHooks");
    private static final ClassDesc COLOR_INFO = ClassDesc.of("zombie.core.textures.ColorInfo");
    private static Handler handler;
    // A game the startup loader started, whose payload has not set the handler yet.
    private static boolean expected;
    private static volatile Power power;
    private static volatile Water water;
    private static volatile Formulas formulas;
    private static volatile Moodles moodles;
    private static volatile Text text;
    private static volatile ZombieSounds zombieSounds;
    // Where IsoObject reads usesExternalWaterSource for itself and keeps the game's flag: saving it, and finding the
    // game's own source (whose return the network's source replaces).
    private static final Set<String> PLUMBING_KEPT = Set.of("save", "checkExternalFluidSource");
    /** The handlers' calls, each reported once; a newer handler of its kind may report again. */
    private enum Call {
        SQUARE("square", Group.POWER), OBJECT("object", Group.POWER), GENERATOR("generator", Group.POWER),
        CONSUMER_CHANGED("consumerChanged", Group.POWER), GENERATOR_UPDATE("generatorUpdate", Group.POWER),
        FOOD_HOURS("foodHours", Group.POWER), WATER_PLUMBED("waterPlumbed", Group.WATER),
        WATER_SOURCE("waterSource", Group.WATER), WATER_SAMPLE("waterSample", Group.WATER),
        WATER_TAINTED("waterTainted", Group.WATER), DISCOMFORT("discomfort", Group.FORMULAS),
        STIFFNESS("stiffness", Group.FORMULAS), FATIGUE("fatigue", Group.FORMULAS), STAT_DELTA("statDelta", Group.FORMULAS),
        INVENTORY_WEIGHT("inventoryWeight", Group.FORMULAS), ITEM_ADDED("itemAdded", Group.FORMULAS),
        ITEM_REMOVED("itemRemoved", Group.FORMULAS), LIST_CLEARED("listCleared", Group.FORMULAS),
        LIST_CHANGED("listChanged", Group.FORMULAS), ITEMS_REPLACING("itemsReplacing", Group.FORMULAS),
        WEIGHT_CHANGED("weightChanged", Group.FORMULAS), FLUID_CHANGED("fluidChanged", Group.FORMULAS),
        INCOMING("incoming", Group.FORMULAS), MAX_WEIGHT("maxWeight", Group.FORMULAS),
        EFFECTIVE_CAPACITY("effectiveCapacity", Group.FORMULAS), CAPACITY("capacity", Group.FORMULAS),
        BAG_CAPACITY("bagCapacity", Group.FORMULAS), BAG_EFFECTIVE_CAPACITY("bagEffectiveCapacity", Group.FORMULAS),
        OVERLOAD("overload", Group.FORMULAS), RUN_PENALTY("runPenalty", Group.FORMULAS),
        COMBAT_PENALTY("combatPenalty", Group.FORMULAS), LOOT_CHANCE("lootChance", Group.FORMULAS),
        LOOT_AMMO("lootAmmo", Group.FORMULAS), DARKNESS("darkness", Group.FORMULAS), CONE_ADD("coneAdd", Group.FORMULAS),
        NIGHT_SIGHT("nightSight", Group.FORMULAS),
        LANDING("landing", Group.FORMULAS), IMPACT("impact", Group.FORMULAS), TREE_SLOW("treeSlow", Group.FORMULAS),
        TREE_ANIMATION("treeAnimation", Group.FORMULAS), TREE_SCRATCH("treeScratch", Group.FORMULAS), WALK("walk", Group.FORMULAS),
        COLD("cold", Group.FORMULAS), CORPSE_COUNT("corpseCount", Group.FORMULAS), CORPSE_SICKNESS("corpseSickness", Group.FORMULAS),
        HOLE("hole", Group.FORMULAS), WOUND("wound", Group.FORMULAS), BITE("bite", Group.FORMULAS),
        MACHINE("machine", Group.FORMULAS), MACHINE_LOAD("machineLoad", Group.FORMULAS), ATTACHED_ANIM("attachedAnim", Group.FORMULAS),
        ANIMATING("animating", Group.FORMULAS), MOODLE_LEVEL("moodleLevel", Group.MOODLES),
        MOODLE_KIND("moodleKind", Group.MOODLES), MOODLE_PICTURE("moodlePicture", Group.MOODLES), TEXT("text", Group.TEXT),
        ZOMBIE_STATE("zombieState", Group.ZOMBIE_SOUNDS), ZOMBIE_VOICE("zombieVoice", Group.ZOMBIE_SOUNDS),
        ZOMBIE_LANDED("zombieLanded", Group.ZOMBIE_SOUNDS);

        final String label;
        final Group group;

        Call(String label, Group group) { this.label = label; this.group = group; }
    }

    /** The handler a call belongs to: a newer one of that handler reports its faults again. */
    private enum Group { POWER, WATER, FORMULAS, MOODLES, TEXT, ZOMBIE_SOUNDS }

    // Guarded by itself. A fault in a call the game makes 40,000 times a second must not flood its log.
    private static final Set<Call> reported = EnumSet.noneOf(Call.class);
    private static final ClassDesc FLUID_CONTAINER = ClassDesc.of("zombie.entity.components.fluids.FluidContainer");
    private static final ClassDesc ARRAY_LIST = ClassDesc.of("java.util.ArrayList"), LIST = ClassDesc.of("java.util.List");
    private static final ClassDesc PLAYER = ClassDesc.of("zombie.characters.IsoPlayer"),
        CHARACTER = ClassDesc.of("zombie.characters.IsoGameCharacter"), VECTOR2 = ClassDesc.of("zombie.iso.Vector2"),
        MOODLE_TYPE = ClassDesc.of("zombie.scripting.objects.MoodleType"), TEXTURE = ClassDesc.of("zombie.core.textures.Texture"),
        ZOMBIE_STATE = ClassDesc.of("zombie.audio.parameters.ParameterZombieState"), ZOMBIE = ClassDesc.of("zombie.characters.IsoZombie"),
        ZOMBIE_STATE_VALUE = ClassDesc.of("zombie.audio.parameters.ParameterZombieState$State");
    // Whether IsoObject, as last transformed, has both hooks that keep a fixture's water tainted.
    private static volatile boolean purifyHooked;
    // UIManager.getToolTip(), which render asks after it has drawn the interface's windows.
    private static final Predicate<CodeElement> TOOLTIP = calls("zombie/ui/UIManager", "getToolTip", "()Lzombie/ui/ObjectTooltip;");

    private ApiHooks() { }

    /** The game classes the hooks go into, and what goes in. */
    private static final Map<String, Site[]> SITES = Map.ofEntries(
        Map.entry("zombie/Lua/LuaManager", new Site[] {
            Site.atReturns("init", "()V", 0, (code, owner) -> {
                code.ldc(owner);
                code.invokestatic(HOOKS, "luaStarted", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Class));
            }) }),
        Map.entry("zombie/iso/IsoGridSquare", new Site[] {
            Site.atReturns("haveElectricity", "()Z", 1, (code, owner) -> {
                for (String axis : new String[] { "x", "y", "z" }) { code.aload(0); code.getfield(owner, axis, ConstantDescs.CD_int); }
                code.invokestatic(HOOKS, "squarePowered", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
                    ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int));
            }).reading("x", "y", "z") }),
        Map.entry("zombie/inventory/ItemContainer", new Site[] {
            Site.atReturns("isObjectPowered", "(Lzombie/iso/IsoObject;Z)Z", 2, (code, owner) -> {
                code.aload(0); code.iconst_0(); code.iload(1); objectPowered(code);
            }),
            // Whether an item fits: each weight the method reads of the item. The first read of a worn bag's is weighed against
            // the character's inventory (it is followed by an addition); the others against this container (they are
            // followed by the call that asks whether it fits).
            Site.edit("hasRoomFor", "(Lzombie/characters/IsoGameCharacter;Lzombie/inventory/InventoryItem;)Z", new Edit(
                calls("zombie/inventory/InventoryItem", "getUnequippedWeight", "()F"), -1, (elements, index) -> {
                    CodeElement next = Edit.after(elements, index);
                    if (next instanceof OperatorInstruction add && add.opcode() == Opcode.FADD) return 1;
                    if (next instanceof InvokeInstruction invoke && invoke.name().equalsString("hasRoomFor")) return 0;
                    throw new IllegalArgumentException("an item's weight is read for something other than a comparison or a room question");
                }, (code, element, viaBag) -> {
                    code.dup();
                    code.with(element);
                    code.aload(0);
                    code.loadConstant(viaBag);
                    code.invokestatic(HOOKS, "incoming", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_Object, ConstantDescs.CD_float,
                        ConstantDescs.CD_Object, ConstantDescs.CD_int));
                })),
            Site.atReturns("getEffectiveCapacity", "(Lzombie/characters/IsoGameCharacter;)I", 2, (code, owner) -> {
                code.aload(0); code.aload(1);
                code.invokestatic(HOOKS, "effectiveCapacity", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_Object,
                    ConstantDescs.CD_Object));
            }),
            Site.atReturns("getCapacity", "()I", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "capacity", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_Object));
            }),
            // The list of items is a Tracked list wherever the game makes it; setItems and emptyIt replace it.
            Site.track("items", ARRAY_LIST, Tracked.ITEMS),
            Site.atStart("emptyIt", "()V", (code, owner) -> thisCall(code, "itemsReplacing")),
            Site.atStart("setItems", "(Ljava/util/ArrayList;)V", (code, owner) -> thisCall(code, "itemsReplacing")) }),
        Map.entry("zombie/characters/WornItems/WornItems", new Site[] { Site.track("items", LIST, Tracked.WORN) }),
        // Everything an item's weight reads is written in these classes (docs/design/extension-api.md, "What the load reads").
        Map.entry("zombie/inventory/InventoryItem", new Site[] {
            Site.watch("weight", "weightChanged", List.of("actualWeight", "ammoType", "currentAmmoCount", "customWeight", "extraItems",
                "fullType", "name", "replaceOnUse", "replaceOnUseFullType", "scriptItem", "cooked", "burnt", "attachedSlot",
                "displayCategory", "itemType"), List.of()),
            Site.atReturns("addExtraItem", "(Ljava/lang/String;)V", 1, (code, owner) -> thisCall(code, "weightChanged")) }),
        Map.entry("zombie/inventory/types/HandWeapon", new Site[] {
            Site.watch("weight", "weightChanged", List.of("containsClip", "roundChambered", "magazineType"), List.of()),
            Site.atReturns("clearAllWeaponParts", "()V", 1, (code, owner) -> thisCall(code, "weightChanged")),
            Site.atReturns("clearWeaponPart", "(Lzombie/inventory/types/WeaponPart;)V", 1, (code, owner) -> thisCall(code, "weightChanged")).named("part"),
            Site.atReturns("clearWeaponPart", "(Ljava/lang/String;)V", 1, (code, owner) -> thisCall(code, "weightChanged")).named("name"),
            Site.atReturns("setWeaponPart", "(Ljava/lang/String;Lzombie/inventory/types/WeaponPart;)V", 1, (code, owner) -> thisCall(code, "weightChanged")),
            Site.atReturns("attachWeaponPart", "(Lzombie/characters/IsoGameCharacter;Lzombie/inventory/types/WeaponPart;Z)V", 1,
                (code, owner) -> thisCall(code, "weightChanged")) }),
        Map.entry("zombie/inventory/types/Moveable", new Site[] { Site.watch("weight", "weightChanged", List.of(), List.of("actualWeight", "fullType", "name")) }),
        Map.entry("zombie/network/packets/ItemStatsPacket", new Site[] { Site.watch("weight", "weightChanged", List.of(), List.of("extraItems")) }),
        Map.entry("zombie/entity/components/fluids/FluidContainer", new Site[] {
            Site.watch("amount", "fluidChanged", List.of("cacheInvalidated", "amountCache"), List.of()) }),
        Map.entry("zombie/iso/objects/IsoLightSwitch", new Site[] {
            Site.atReturns("hasElectricityAround", "()Z", 1, (code, owner) -> {
                code.aload(0); code.iconst_1(); code.iconst_1(); objectPowered(code);
            }) }),
        Map.entry("zombie/radio/devices/DeviceData", new Site[] {
            Site.atReturns("canBePoweredHere", "()Z", 1, (code, owner) -> {
                code.aload(0); code.iconst_2(); code.iconst_1(); objectPowered(code);
            }) }),
        Map.entry("zombie/iso/LightingJNI", new Site[] {
            // switch.square.haveElectricity(), for each switch of a room whose light is checked.
            Site.square("checkLights", "()V", element -> element instanceof FieldInstruction field
                && field.opcode() == Opcode.GETFIELD && field.owner().asInternalName().equals("zombie/iso/objects/IsoLightSwitch")
                && field.name().equalsString("square"), ROOM_LIGHT),
            // How dark it is for the character, from 0 to 1 (private; the vision cone and the native lighting read it).
            Site.atReturns("getLumaInverted", "(Lzombie/characters/IsoGameCharacter;)F", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "darkness", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
            }),
            // degrees x worn items' multiplier: the degrees, then the character, are on the stack. The traits add to the degrees just before.
            Site.before("calculateVisionCone", "(Lzombie/characters/IsoGameCharacter;)F", (second, first, element) -> element instanceof InvokeInstruction invoke
                && invoke.name().equalsString("getWornItemsVisionMultiplier") && invoke.type().equalsString("()F")
                && first instanceof LoadInstruction self && self.slot() == 0 && self.typeKind() == TypeKind.REFERENCE
                && second instanceof LoadInstruction degrees && degrees.typeKind() == TypeKind.FLOAT, (code, owner) -> {
                    code.swap();
                    code.invokestatic(HOOKS, "coneAdd", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_Object, ConstantDescs.CD_float));
                    code.aload(0);
                }) }),
        // Night sight's least light: each read of a square's lighting from the native lighting (the call hands it into an
        // int[]) is followed by squareLit with the same player, square and array, before the game reads the corners out of
        // it; and the lighting's answer whether a square changed is followed by squareStale's, so that a square raised to
        // another least light is read again (the native lighting does not know of it).
        Map.entry("zombie/iso/LightingJNI$JNILighting", new Site[] {
            Site.edit("update", "()V", new Edit(squareLightingCall(), -1, null, ApiHooks::squareLighting)),
            Site.edit("updateFBORenderChunk", "()V", new Edit(squareLightingCall(), -1, null, ApiHooks::squareLighting)),
            Site.edit("update", "()V", new Edit(squareDirtyCall(), -1, null, ApiHooks::squareDirtyCheck)).named("stale"),
            Site.edit("updateFBORenderChunk", "()V", new Edit(squareDirtyCall(), -1, null, ApiHooks::squareDirtyCheck)).named("stale") }),
        // The light a square's objects are drawn with (the square's own, which the game also asks for its zombies and vision).
        Map.entry("zombie/iso/fboRenderChunk/FBORenderCell", new Site[] {
            Site.atReturns("sanitizeLightInfo", "(ILzombie/iso/IsoGridSquare;)Lzombie/core/textures/ColorInfo;", 3, (code, owner) -> {
                code.iload(1);
                code.invokestatic(HOOKS, "objectLight", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object, ConstantDescs.CD_int));
                code.checkcast(COLOR_INFO);
            }) }),
        // Night sight's screen pass: a step put into the screen shader where it reads the world (ScreenShader), its program kept
        // when the shader compiles and its uniforms set each time it draws; night sight moves on once a frame before.
        Map.entry("zombie/core/opengl/ShaderUnit", new Site[] {
            Site.atReturns("loadShaderFile", "(Ljava/lang/String;Ljava/util/ArrayList;)Ljava/lang/String;", 3, (code, owner) -> {
                code.aload(1);
                code.invokestatic(HOOKS, "shaderSource", MethodTypeDesc.of(ConstantDescs.CD_String, ConstantDescs.CD_String, ConstantDescs.CD_String));
            }) }),
        Map.entry("zombie/iso/weather/WeatherShader", new Site[] {
            Site.atReturns("onCompileSuccess", "(Lzombie/core/opengl/ShaderProgram;)V", 2, (code, owner) -> {
                code.aload(0);
                code.invokevirtual(owner, "getID", MethodTypeDesc.of(ConstantDescs.CD_int));
                code.invokestatic(HOOKS, "nightSightProgram", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_int));
            }),
            Site.atStart("startMainThread", "(Lzombie/core/textures/TextureDraw;I)V", (code, owner) -> {
                code.iload(2);
                code.invokestatic(HOOKS, "nightSightFrame", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_int));
            }),
            Site.atReturns("startRenderThread", "(Lzombie/core/textures/TextureDraw;)V", 2, (code, owner) -> {
                code.aload(0);
                code.invokevirtual(owner, "getID", MethodTypeDesc.of(ConstantDescs.CD_int));
                code.invokestatic(HOOKS, "nightSightDraw", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_int));
            }) }),
        Map.entry("zombie/inventory/types/Food", new Site[] {
            // container.getSourceGrid().haveElectricity(), for food in a fridge or freezer.
            Site.square("updateAge", "(Z)V", element -> element instanceof InvokeInstruction invoke
                && invoke.owner().asInternalName().equals("zombie/inventory/ItemContainer")
                && invoke.name().equalsString("getSourceGrid"), FOOD).named("power"),
            // age + hours * this.getFoodRotSpeed() / 24: the hours, then this, are on the stack.
            Site.before("updateAge", "(Z)V", (second, first, element) -> element instanceof InvokeInstruction invoke
                && invoke.name().equalsString("getFoodRotSpeed") && invoke.type().equalsString("()F")
                && first instanceof LoadInstruction self && self.slot() == 0 && self.typeKind() == TypeKind.REFERENCE
                && second instanceof LoadInstruction hours && hours.typeKind() == TypeKind.DOUBLE, (code, owner) -> {
                    code.pop();
                    code.aload(0);
                    code.invokestatic(HOOKS, "foodHours", MethodTypeDesc.of(ConstantDescs.CD_double, ConstantDescs.CD_double,
                        ConstantDescs.CD_Object));
                    code.aload(0);
                }).named("hours"),
            Site.watch("weight", "weightChanged", List.of("baseHunger", "hungChange", "thirstChange"), List.of("burnt")) }),
        // The helicopter is on or off, and in a state, by these two fields alone (isActive reads active): every store of either, in any
        // method, counts a write for the API to look at on the game's thread.
        Map.entry("zombie/iso/Helicopter", new Site[] { Site.watch("flight", "helicopterChanged", List.of("state", "active"), List.of()) }),
        // The world's cell is IsoWorld.currentCell (getCell reads it); it is stored when the world starts and when it is killed.
        Map.entry("zombie/iso/IsoWorld", new Site[] { Site.watch("currentCell", "worldChanged", List.of("currentCell"), List.of()) }),
        Map.entry("zombie/iso/IsoObject", new Site[] {
            // The water questions' reads of usesExternalWaterSource are hooked too; see plumbing.
            Site.atReturns("checkExternalFluidSource", "()Lzombie/iso/IsoObject;", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "waterSource", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                    ConstantDescs.CD_Object));
                code.checkcast(owner);
            }),
            // At the start: the method reassigns its amount. A sample from the API is returned in place of the game's.
            Site.atStart("createSampleAndPurifyWater",
                "(Lzombie/entity/components/fluids/FluidContainer;F)Lzombie/entity/components/fluids/FluidContainer;", (code, owner) -> {
                    Label vanilla = code.newLabel();
                    code.aload(0); code.aload(1); code.fload(2);
                    code.invokestatic(HOOKS, "waterSample", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                        ConstantDescs.CD_Object, ConstantDescs.CD_float));
                    code.dup();
                    code.ifnull(vanilla);
                    code.checkcast(FLUID_CONTAINER);
                    code.areturn();
                    code.labelBinding(vanilla);
                    code.pop();
                }),
            Site.atReturns("isTaintedWater", "()Z", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "waterTainted", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
                    ConstantDescs.CD_Object));
            }),
            // The machines mods declare (docs/design/extension-api.md, "Machines"): the two questions a generator asks of an
            // object. Nothing else hooks them; the buildings and networks areas read them, and so follow.
            Site.atReturns("couldBePoweredByGenerator", "()Z", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "machine", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean, ConstantDescs.CD_Object));
            }),
            Site.atReturns("getGeneratorPowerConsumption", "()F", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "machineLoad", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
            }),
            // The animations attached to an object (docs/design/extension-api.md, "Attached animations"): the game draws each and
            // then calls its update(), which does nothing. That call stays; after it the instance and the object go to the API.
            Site.edit("renderAttachedSprites", "(Lzombie/iso/IsoDirections;FFFLzombie/core/textures/ColorInfo;ZLzombie/core/opengl/Shader;"
                + "Ljava/util/function/Consumer;)V", new Edit(calls("zombie/iso/sprite/IsoSpriteInstance", "update", "()V"), 1, null,
                    (code, element, kind) -> {
                        // instance -> instance, instance -> instance; the call -> instance, this -> hook
                        code.dup();
                        code.with(element);
                        code.aload(0);
                        code.invokestatic(HOOKS, "attachedAnim", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object, ConstantDescs.CD_Object));
                    })),
            // The chunk renderer draws an object into the chunk's texture, again only when the chunk changes, unless it asks to be drawn
            // every frame (FBORenderCell's layers: a fire, or an object isAnimating says yes to). A stepped object says yes.
            Site.atReturns("isAnimating", "()Z", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "animating", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean, ConstantDescs.CD_Object));
            }) }),
        Map.entry("zombie/iso/objects/IsoGenerator", new Site[] {
            Site.atStart("setSurroundingElectricity", "()V", (code, owner) -> {
                Label vanilla = code.newLabel();
                code.aload(0);
                code.invokestatic(HOOKS, "generatorSurrounding", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_Object));
                code.ifeq(vanilla);
                code.return_();
                code.labelBinding(vanilla);
            }),
            Site.atStart("updateGenerator", "(Lzombie/iso/IsoGridSquare;)V", (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "consumerChanged", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object));
            }),
            Site.atStart("update", "()V", (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "generatorUpdate", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object));
            }) }),
        // The formulas (docs/design/extension-api.md, "Formulas"): each hook changes the game's own answer for the
        // local player's character when a mod declared a formula for it.
        Map.entry("zombie/characters/IsoGameCharacter", new Site[] {
            Site.atReturns("getClothingDiscomfortModifier", "()F", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "discomfort", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
            }),
            // The amount is the method's own argument: the hook replaces it before the method uses it.
            Site.atStart("addStiffness", "(Lzombie/characters/BodyDamage/BodyPartType;F)V", (code, owner) -> {
                code.fload(2);
                code.aload(0);
                code.invokestatic(HOOKS, "stiffness", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
                code.fstore(2);
            }),
            Site.atReturns("getFatiqueMultiplier", "()D", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "fatigue", MethodTypeDesc.of(ConstantDescs.CD_double, ConstantDescs.CD_double, ConstantDescs.CD_Object));
            }),
            // How heavy the inventory is with the load's formulas: the API keeps the sum and answers at once, or NaN for the game's own walk.
            Site.atStart("getInventoryWeight", "()F", (code, owner) -> {
                Label known = code.newLabel();
                code.aload(0);
                code.invokestatic(HOOKS, "inventoryWeight", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_Object));
                code.dup();
                code.dup();
                code.fcmpl();
                code.ifne(known);
                code.freturn();
                code.labelBinding(known);
                code.pop();
            }),
            Site.atReturns("getMaxWeight", "()I", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "maxWeight", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_Object));
            }),
            // How heavily the character is loaded, three times, as the fall damage is worked out.
            Site.edit("handleLandingImpact", "(Lzombie/characters/FallDamage;)V", overloadEdit(3)).named("overload"),
            // The speed the damage is worked out from, replaced where the fall damage reads it.
            Site.edit("handleLandingImpact", "(Lzombie/characters/FallDamage;)V", new Edit(calls("zombie/characters/FallDamage",
                "getImpactIsoSpeed", "()F"), 1, null, (code, element, kind) -> {
                    code.with(element);
                    code.aload(0);
                    code.invokestatic(HOOKS, "impact", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
                })).named("impact"),
            // The speed of a landing is the method's own argument: replaced before the method uses it.
            Site.atStart("DoLand", "(F)V", (code, owner) -> {
                code.fload(1);
                code.aload(0);
                code.invokestatic(HOOKS, "landing", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
                code.fstore(1);
            }),
            // Whether walking through trees goes on to hurt (and tear the clothes): false returns at once.
            Site.atStart("damageWhileInTrees", "()V", (code, owner) -> {
                Label scratch = code.newLabel();
                code.aload(0);
                code.invokestatic(HOOKS, "treeScratch", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_Object));
                code.ifne(scratch);
                code.return_();
                code.labelBinding(scratch);
            }),
            // Whether clothes tear: false returns false at once (no hole made).
            Site.atStart("addHole", "(Lzombie/characterTextures/BloodBodyPartType;Z)Z", (code, owner) -> {
                Label hole = code.newLabel();
                code.aload(0);
                code.invokestatic(HOOKS, "hole", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_Object));
                code.ifne(hole);
                code.iconst_0();
                code.ireturn();
                code.labelBinding(hole);
            }),
            // The full speed modifier is stored; the combat speed modifier is read once.
            Site.edit("calculateBaseSpeed", "()F", new Edit(field(Opcode.PUTFIELD, "zombie/characters/IsoGameCharacter", "fullSpeedMod"), 1, null,
                (code, element, kind) -> {
                    code.aload(0);
                    code.invokestatic(HOOKS, "runPenalty", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
                    code.with(element);
                })),
            Site.edit("calculateCombatSpeed", "()F", new Edit(field(Opcode.GETFIELD, "zombie/characters/IsoGameCharacter", "combatSpeedModifier"), 1, null,
                (code, element, kind) -> {
                    code.with(element);
                    code.aload(0);
                    code.invokestatic(HOOKS, "combatPenalty", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
                })) }),
        Map.entry("zombie/characters/IsoPlayer", new Site[] {
            Site.edit("getPathSpeed", "()F", overloadEdit(1)).named("overload"),
            Site.atReturns("calculateInTreesSpeed", "()F", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "treeAnimation", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
            }),
            // The movement the animation gives is a Vector2 the method changes and returns: scaled in place before each return,
            // and not at all when there is nothing to scale by.
            Site.atReturns("getDeferredMovement", "(Lzombie/iso/Vector2;Z)Lzombie/iso/Vector2;", 1, (code, owner) -> {
                Label unchanged = code.newLabel(), done = code.newLabel();
                code.dup();
                code.aload(0);
                code.invokestatic(HOOKS, "walk", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_Object));
                code.dup();
                code.fconst_1();
                code.fcmpl();
                code.ifeq(unchanged);
                code.invokevirtual(VECTOR2, "scale", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_float));
                code.goto_(done);
                code.labelBinding(unchanged);
                code.pop();
                code.pop();
                code.labelBinding(done);
            }) }),
        Map.entry("zombie/characters/Moodles/Moodle", new Site[] {
            Site.edit("Update", "()Z", overloadEdit(1)).named("overload"),
            // The moodles mods define (docs/design/extension-api.md, "Moodles"): the level of one of the API's types goes through the
            // game's own updateMoodleLevel, so that the moodle column refreshes and wiggles as for the game's; -1 runs the game's update.
            Site.atStart("Update", "()Z", (code, owner) -> {
                Label vanilla = code.newLabel();
                code.aload(0);
                code.aload(0);
                code.getfield(owner, "moodleType", MOODLE_TYPE);
                code.aload(0);
                code.getfield(owner, "isoGameCharacter", CHARACTER);
                code.invokestatic(HOOKS, "moodleLevel", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_Object, ConstantDescs.CD_Object));
                code.dup();
                code.iflt(vanilla);
                code.invokespecial(owner, "updateMoodleLevel", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_int));
                code.ireturn();
                code.labelBinding(vanilla);
                code.pop2();
            }).named("level").reading("moodleType:Lzombie/scripting/objects/MoodleType;", "isoGameCharacter:Lzombie/characters/IsoGameCharacter;",
                "updateMoodleLevel:(I)Z") }),
        Map.entry("zombie/characters/Moodles/Moodles", new Site[] {
            // Every character's moodles as they are made: a type defined later is added to them (see Moodles in the API).
            Site.atReturns("<init>", "(Lzombie/characters/IsoGameCharacter;)V", 2, (code, owner) -> thisCall(code, "moodlesMade")),
            Site.atReturns("GoodBadNeutral", "(Lzombie/scripting/objects/MoodleType;)I", 2, (code, owner) -> {
                code.aload(1);
                code.invokestatic(HOOKS, "moodleKind", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_Object));
            }) }),
        // The picture the moodle column draws: the set's own, or for a type the set has none for, the API's (set, type -> texture).
        Map.entry("zombie/ui/MoodlesUI", new Site[] {
            Site.edit("render", "()V", new Edit(calls("zombie/ui/MoodleTextureSet", "getTexture",
                "(Lzombie/scripting/objects/MoodleType;)Lzombie/core/textures/Texture;"), 1, null, (code, element, kind) -> {
                    code.dup2();
                    code.with(element);
                    code.aload(0);
                    code.invokestatic(HOOKS, "moodlePicture", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                        ConstantDescs.CD_Object, ConstantDescs.CD_Object, ConstantDescs.CD_Object));
                    code.checkcast(TEXTURE);
                })) }),
        // The text mods show (docs/design/extension-api.md, "Text"): drawn once the interface's windows are, before the tooltip,
        // the paused message and the fade the game draws over the interface. That is where render first asks for the tooltip
        // (it asks twice: whether there is one, and to draw it), on every path that draws the interface.
        Map.entry("zombie/ui/UIManager", new Site[] {
            Site.edit("render", "()V", new Edit(TOOLTIP, 2, (elements, index) -> {
                int before = 0;
                for (int earlier = 0; earlier < index; earlier++) if (TOOLTIP.test(elements.get(earlier))) before++;
                return before;
            }, (code, element, order) -> {
                if (order == 0) code.invokestatic(HOOKS, "uiDrawn", MethodTypeDesc.of(ConstantDescs.CD_void));
                code.with(element);
            })).named("text") }),
        // A bag clamps its capacity to what a bag can be (50 less its own weight), over the container's own.
        Map.entry("zombie/inventory/types/InventoryContainer", new Site[] {
            Site.atReturns("getCapacity", "()I", 1, (code, owner) -> {
                code.aload(0);
                code.invokestatic(HOOKS, "bagCapacity", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_Object));
            }),
            Site.atReturns("getEffectiveCapacity", "(Lzombie/characters/IsoGameCharacter;)I", 2, (code, owner) -> {
                code.aload(0); code.aload(1);
                code.invokestatic(HOOKS, "bagEffectiveCapacity", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_Object,
                    ConstantDescs.CD_Object));
            }),
            Site.watch("weight", "weightChanged", List.of("container", "weightReduction"), List.of()) }),
        // The loot: the chance of an item, and the ammunition modifier.
        Map.entry("zombie/inventory/ItemPickerJava", new Site[] {
            Site.atReturns("getActualSpawnChance", "(Lzombie/inventory/ItemPickerJava$ItemPickerItem;Lzombie/characters/IsoGameCharacter;"
                + "Lzombie/inventory/ItemContainer;FZ)F", 0, (code, owner) -> code.invokestatic(HOOKS, "lootChance",
                    MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float))),
            Site.edit("getLootModifierFromType", "(Ljava/lang/String;)F", new Edit(field(Opcode.GETSTATIC, "zombie/inventory/ItemPickerJava",
                "ammoLootModifier"), 1, null, (code, element, kind) -> {
                    code.with(element);
                    code.invokestatic(HOOKS, "lootAmmo", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float));
                })) }),
        Map.entry("zombie/iso/objects/IsoTree", new Site[] {
            Site.atReturns("getSlowFactor", "(Lzombie/iso/IsoMovingObject;)F", 2, (code, owner) -> {
                code.aload(1);
                code.invokestatic(HOOKS, "treeSlow", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
            }) }),
        // The body: a cold, the corpses around, a wound's infection and a bite.
        Map.entry("zombie/characters/BodyDamage/Thermoregulator", new Site[] {
            Site.atReturns("getCatchAColdDelta", "()F", 1, (code, owner) -> {
                code.aload(0);
                code.getfield(owner, "player", PLAYER);
                code.invokestatic(HOOKS, "cold", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
            }).reading("player:Lzombie/characters/IsoPlayer;") }),
        Map.entry("zombie/iso/CorpseCount", new Site[] {
            Site.atReturns("getCorpseCount", "(Lzombie/characters/IsoGameCharacter;)I", 2, (code, owner) -> {
                code.aload(1);
                code.invokestatic(HOOKS, "corpseCount", MethodTypeDesc.of(ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_Object));
            }) }),
        Map.entry("zombie/characters/BodyDamage/BodyDamage", new Site[] {
            Site.atReturns("GetBaseCorpseSickness", "()F", 1, (code, owner) -> {
                code.aload(0);
                code.getfield(owner, "parentChar", CHARACTER);
                code.invokestatic(HOOKS, "corpseSickness", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_float, ConstantDescs.CD_Object));
            }).reading("parentChar:Lzombie/characters/IsoGameCharacter;"),
            // The one place a zombie's bite is put on a body part: SetBitten(index, true) with the index in a local. (Loading a
            // save calls BodyPart.SetBitten too, which is why the hook is here and not in BodyPart.)
            Site.edit("AddRandomDamageFromZombie", "(Lzombie/characters/IsoZombie;Ljava/lang/String;I)Z", new Edit(
                calls("zombie/characters/BodyDamage/BodyDamage", "SetBitten", "(IZ)V"), 1, (elements, index) -> {
                    // iload <index>; iconst_1; invokevirtual SetBitten(IZ)V
                    CodeElement[] before = new CodeElement[2];
                    int found = 0;
                    for (int back = index - 1; back >= 0 && found < 2; back--)
                        if (elements.get(back) instanceof Instruction) before[found++] = elements.get(back);
                    if (found == 2 && before[0] instanceof ConstantInstruction one && one.constantValue().equals(1)
                            && before[1] instanceof LoadInstruction load && load.typeKind() == TypeKind.INT) return load.slot();
                    throw new IllegalArgumentException("the bite is not put on a body part by a local index");
                }, (code, element, slot) -> {
                    code.aload(0);
                    code.iload(slot);
                    code.iconst_0();
                    code.invokestatic(HOOKS, "bite", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object, ConstantDescs.CD_int, ConstantDescs.CD_int));
                    code.with(element);
                    code.aload(0);
                    code.iload(slot);
                    code.iconst_1();
                    code.invokestatic(HOOKS, "bite", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object, ConstantDescs.CD_int, ConstantDescs.CD_int));
                })) }),
        Map.entry("zombie/characters/BodyDamage/BodyPart", new Site[] {
            Site.atStart("generateZombieInfection", "(I)V", (code, owner) -> {
                Label roll = code.newLabel();
                code.aload(0);
                code.getfield(owner, "parentChar", CHARACTER);
                code.invokestatic(HOOKS, "wound", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_Object));
                code.ifne(roll);
                code.return_();
                code.labelBinding(roll);
            }).reading("parentChar:Lzombie/characters/IsoGameCharacter;") }),
        Map.entry("zombie/characters/Stats", new Site[] {
            // add(stat, delta); remove(stat, amount) is add(stat, -amount).
            Site.atStart("add", "(Lzombie/characters/CharacterStat;F)Z", (code, owner) -> {
                code.aload(0);
                code.aload(1);
                code.fload(2);
                code.invokestatic(HOOKS, "statDelta", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                    ConstantDescs.CD_float));
                code.fstore(2);
            }) }),
        // The sounds zombies make that the game hands to FMOD alone (docs/design/extension-api.md, "Zombie sounds"). The state a
        // zombie's voice is played in: the store of the new state, which comes after the game's early return for the same one (the
        // new state from the stack, the zombie and the old state read from the parameter).
        Map.entry("zombie/audio/parameters/ParameterZombieState", new Site[] {
            Site.edit("setState", "(Lzombie/audio/parameters/ParameterZombieState$State;)V", new Edit(field(Opcode.PUTFIELD,
                "zombie/audio/parameters/ParameterZombieState", "state"), 1, null, (code, element, kind) -> {
                    // this, to -> this, to, to, zombie, from -> this, to
                    code.dup();
                    code.aload(0);
                    code.getfield(ZOMBIE_STATE, "zombie", ZOMBIE);
                    code.aload(0);
                    code.getfield(ZOMBIE_STATE, "state", ZOMBIE_STATE_VALUE);
                    code.invokestatic(HOOKS, "zombieState", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                        ConstantDescs.CD_Object));
                    code.with(element);
                })).reading("zombie:Lzombie/characters/IsoZombie;", "state:Lzombie/audio/parameters/ParameterZombieState$State;") }),
        // A zombie's voice starting: the one call of playVocals, which the slot makes when the zombie has no voice playing (the
        // zombie is the method's argument, which the method never stores over).
        Map.entry("zombie/characters/ZombieVocalsManager$Slot", new Site[] {
            Site.edit("playSound", "(Lzombie/characters/IsoZombie;)V", new Edit(calls("zombie/characters/BaseCharacterSoundEmitter", "playVocals",
                "(Ljava/lang/String;)J"), 1, (elements, index) -> {
                    for (CodeElement element : elements)
                        if (element instanceof StoreInstruction store && store.slot() == 1)
                            throw new IllegalArgumentException("the zombie argument is stored over");
                    return 0;
                }, (code, element, kind) -> {
                    code.aload(1);
                    code.invokestatic(HOOKS, "zombieVoice", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object));
                    code.with(element);
                })) }),
        // A zombie landing from a fall: the zombie's own handleLandingImpact, which DoLand calls for a landing the game counts as a fall.
        Map.entry("zombie/characters/IsoZombie", new Site[] {
            Site.atStart("handleLandingImpact", "(Lzombie/characters/FallDamage;)V", (code, owner) -> thisCall(code, "zombieLanded")) }));

    /** {@code this}, passed to the static call {@code name(Object)}. */
    private static void thisCall(CodeBuilder code, String name) {
        code.aload(0);
        code.invokestatic(HOOKS, name, MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object));
    }

    /** The result of each {@code ItemContainer.getCapacityWeight()} call, with the container it was asked of. */
    private static Edit overloadEdit(int expected) {
        return new Edit(calls("zombie/inventory/ItemContainer", "getCapacityWeight", "()F"), expected, null, (code, element, kind) -> {
            code.dup();
            code.with(element);
            code.invokestatic(HOOKS, "overload", MethodTypeDesc.of(ConstantDescs.CD_float, ConstantDescs.CD_Object, ConstantDescs.CD_float));
        });
    }

    private static void objectPowered(CodeBuilder code) {
        code.invokestatic(HOOKS, "objectPowered", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
            ConstantDescs.CD_Object, ConstantDescs.CD_int, ConstantDescs.CD_boolean));
    }

    /**
     * In a game the startup loader started, before the game loads its Lua and its world: the hooks go in as the classes
     * load. A class the game loaded already (the app's helper got in first) is transformed again.
     */
    static void install(Instrumentation instrumentation) {
        synchronized (ApiHooks.class) { expected = true; }
        ClassFileTransformer transformer = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (name == null || !SITES.containsKey(name)) return null;
                try { return ApiHooks.transform(name, bytes, loader); }
                catch (Throwable problem) { failed(name, String.valueOf(problem)); return null; }
            }
        };
        // Stays registered, so that the hooks survive another agent's retransformation (see AgentEntry.ensureGameHook).
        instrumentation.addTransformer(transformer, true);
        var loaded = new ArrayList<Class<?>>();
        for (Class<?> type : instrumentation.getAllLoadedClasses())
            if (SITES.containsKey(type.getName().replace('.', '/')) && instrumentation.isModifiableClass(type)) loaded.add(type);
        if (loaded.isEmpty()) return;
        try { instrumentation.retransformClasses(loaded.toArray(Class<?>[]::new)); }
        catch (Throwable problem) {
            for (Class<?> type : loaded) failed(type.getName().replace('.', '/'), "the loaded class could not be changed: " + problem);
        }
    }

    /** Every hook of the class, when the class could not be read or changed at all. */
    private static void failed(String name, String problem) {
        for (Site site : SITES.get(name)) record(site.label(name), problem);
        if ("zombie/iso/IsoObject".equals(name)) { record(PLUMBING, problem); purifyHooked = false; }
    }

    /**
     * The hooked class, or null when none of its hooks fits. Each hook is checked and put in on its own: a method another
     * mod has changed loses its own hook only, and {@link #hookStatus} says which and why.
     */
    static byte[] transform(String name, byte[] bytes, ClassLoader loader) {
        Site[] sites = SITES.get(name);
        if (sites == null) return null;
        var cf = GameHook.classFile(loader);
        var model = cf.parse(bytes);
        ClassDesc owner = model.thisClass().asSymbol();
        var parts = new LinkedHashMap<String, ClassTransform>();
        for (Site site : sites) {
            String problem = site.problem(name, model);
            if (problem == null) parts.put(site.label(name), site.classTransform(owner));
            else record(site.label(name), problem);
        }
        if ("zombie/iso/IsoObject".equals(name)) {
            try { parts.put(PLUMBING, plumbing(model, owner)); }
            catch (IllegalArgumentException unfit) { record(PLUMBING, unfit.getMessage()); }
        }
        // The class is built with every fitting hook at once; should that fail (new stack maps that cannot be made, say),
        // the hooks go in one at a time and only the ones the class takes stay.
        byte[] result = null;
        var kept = new LinkedHashMap<String, ClassTransform>();
        try {
            if (!parts.isEmpty()) result = cf.transformClass(model, combine(parts.values()));
            kept.putAll(parts);
        } catch (RuntimeException together) {
            for (var part : parts.entrySet()) {
                var trial = new ArrayList<>(kept.values());
                trial.add(part.getValue());
                try {
                    result = cf.transformClass(model, combine(trial));
                    kept.put(part.getKey(), part.getValue());
                } catch (RuntimeException alone) { record(part.getKey(), "its code could not be built: " + alone.getMessage()); }
            }
        }
        for (String label : kept.keySet()) record(label, APPLIED);
        // The class as it is now: a later transform (another agent's, say) may keep one of the two hooks, or neither.
        if ("zombie/iso/IsoObject".equals(name)) purifyHooked = kept.containsKey(PURIFY) && kept.containsKey(TAINTED);
        return kept.isEmpty() ? null : result;
    }

    private static ClassTransform combine(Collection<ClassTransform> parts) {
        ClassTransform transform = ClassTransform.ACCEPT_ALL;
        for (ClassTransform part : parts) transform = transform.andThen(part);
        return transform;
    }

    // ---- what went in ----

    /** A hook's state in {@link #hookStatus}; anything else is why it did not go in. */
    public static final String APPLIED = "applied", NOT_LOADED = "not-loaded";
    private static final String PLUMBING = "IsoObject.waterQuestions", PURIFY = "IsoObject.createSampleAndPurifyWater",
        TAINTED = "IsoObject.isTaintedWater";
    // Guarded by itself. By label: applied, or why not; a class that has not loaded yet is not in it.
    private static final Map<String, String> status = new HashMap<>();

    private static void record(String label, String state) {
        synchronized (status) {
            status.put(label, state);
            helicopterWatched = APPLIED.equals(status.get(HELICOPTER_WATCH));
            worldWatched = APPLIED.equals(status.get(WORLD_WATCH));
            String pictures = status.get(MOODLE_PICTURES);
            moodlePicturesHooked = pictures == null || APPLIED.equals(pictures);
            moodlesFollowed = APPLIED.equals(status.get(MOODLES_MADE));
            if (TRACKING.contains(label)) {
                boolean sound = true;
                for (String needed : TRACKING) {
                    String seen = status.get(needed);
                    if (seen != null && !APPLIED.equals(seen)) sound = false;
                }
                weightTracked = sound;
            }
        }
        if (!APPLIED.equals(state)) System.err.println("[PzTools API] no hook in " + label + ": " + state);
    }

    /**
     * The hooks that let the API keep an exact account of the inventory's weight (it is told of every change to a list of
     * items and every write of a field the weight reads); with one of them missing the account would drift, and the API
     * leaves the game's own weight alone.
     */
    private static final List<String> TRACKING = List.of("ItemContainer.items:tracked", "ItemContainer.emptyIt", "ItemContainer.setItems",
        "WornItems.items:tracked", "InventoryItem.writes:weight", "InventoryItem.addExtraItem", "Food.writes:weight",
        "HandWeapon.writes:weight", "HandWeapon.clearAllWeaponParts", "HandWeapon.clearWeaponPart:part", "HandWeapon.clearWeaponPart:name",
        "HandWeapon.setWeaponPart", "HandWeapon.attachWeaponPart", "InventoryContainer.writes:weight", "Moveable.writes:weight",
        "ItemStatsPacket.writes:weight", "FluidContainer.writes:amount", "IsoGameCharacter.getInventoryWeight");
    private static volatile boolean weightTracked = true;

    // What the API drains on the game's thread instead of looking each frame: how many times the helicopter's state or flag, and the
    // world's cell, were stored since the game started; any thread may count. Meaningful only while the matching hook is applied.
    private static final String HELICOPTER_WATCH = "Helicopter.writes:flight", WORLD_WATCH = "IsoWorld.writes:currentCell";
    private static final AtomicInteger helicopterWrites = new AtomicInteger(), worldWrites = new AtomicInteger();
    private static volatile boolean helicopterWatched, worldWatched;

    /** Put after each store of {@code Helicopter.state} or {@code Helicopter.active}; it only counts. */
    public static void helicopterChanged(Object helicopter) { helicopterWrites.incrementAndGet(); }

    /** Put after each store of {@code IsoWorld.currentCell}; it only counts. */
    public static void worldChanged(Object world) { worldWrites.incrementAndGet(); }

    /** How many stores of the helicopter's state or flag the hooks counted. */
    public static int helicopterWrites() { return helicopterWrites.get(); }

    /** How many stores of the world's cell the hooks counted. */
    public static int worldWrites() { return worldWrites.get(); }

    /** Whether the hook on the stores of the helicopter's state and flag is in the class the game runs. */
    public static boolean helicopterWatched() { return helicopterWatched; }

    /** Whether the hook on the stores of the world's cell is in the class the game runs. */
    public static boolean worldWatched() { return worldWatched; }

    // The moodle column's picture hook, and the hook that sees every character's moodles made.
    private static final String MOODLE_PICTURES = "MoodlesUI.render", MOODLES_MADE = "Moodles.<init>";
    // True until MoodlesUI was tried without its hook: the column then has no picture for a type the API defines.
    private static volatile boolean moodlePicturesHooked = true, moodlesFollowed;
    // Every character's moodles (Moodles) made since the game started, held weakly: a type defined later is added to them.
    private static final Set<Object> madeMoodles = Collections.synchronizedSet(Collections.newSetFromMap(new WeakHashMap<>()));

    /**
     * Whether the moodle column can draw a picture for a type the API defines: its hook is in, or its class has not loaded yet
     * (nothing draws then). Without it, the API shows none of its moodles: the game's column would fail to draw one.
     */
    public static boolean moodlePicturesHooked() { return moodlePicturesHooked; }

    /** Whether {@link #madeMoodles()} holds every character's moodles: the hook in their constructor is in. */
    public static boolean moodlesFollowed() { return moodlesFollowed; }

    /** Put at the end of the constructor of {@code Moodles}, a character's moodles. */
    public static void moodlesMade(Object moodles) { madeMoodles.add(moodles); }

    /** The characters' moodles that are still about, in no order. */
    public static List<Object> madeMoodles() {
        synchronized (madeMoodles) { return new ArrayList<>(madeMoodles); }
    }

    /** Whether every hook of {@link #TRACKING} that was tried went in (a class that has not loaded yet has nothing to track). */
    public static boolean weightTracked() { return weightTracked; }

    /**
     * Every hook the API puts into the game, by game class and method ({@code IsoGridSquare.haveElectricity}): applied,
     * not-loaded (its class has not loaded yet; most load with the first world), or why it did not go in. A question
     * whose hook is missing gets the game's own answer.
     */
    public static Map<String, String> hookStatus() {
        var all = new TreeMap<String, String>();
        for (var entry : SITES.entrySet())
            for (Site site : entry.getValue()) all.put(site.label(entry.getKey()), NOT_LOADED);
        all.put(PLUMBING, NOT_LOADED);
        synchronized (status) { all.putAll(status); }
        return all;
    }

    /**
     * Rewrites the instructions of a method that {@code matcher} picks. {@code emit} writes the instruction itself and
     * what goes with it; {@code kinds} tells each place apart from the code around it (null: all alike) and may refuse
     * a shape it does not expect. {@code expected} is how many places there must be, or -1 for one or more.
     */
    private record Edit(Predicate<CodeElement> matcher, int expected, Kinds kinds, Emit emit) {
        @FunctionalInterface interface Kinds { int kind(List<CodeElement> elements, int index); }

        @FunctionalInterface interface Emit { void emit(CodeBuilder code, CodeElement element, int kind); }

        /** The kind of each place the matcher picks, in order. */
        int[] kindsIn(List<CodeElement> elements) {
            var found = new ArrayList<Integer>();
            for (int index = 0; index < elements.size(); index++)
                if (matcher.test(elements.get(index))) found.add(kinds == null ? 0 : kinds.kind(elements, index));
            return found.stream().mapToInt(Integer::intValue).toArray();
        }

        /** The next instruction after the one at {@code index} that is not a constant being pushed, or null. */
        static CodeElement after(List<CodeElement> elements, int index) {
            for (int next = index + 1; next < elements.size(); next++)
                if (elements.get(next) instanceof Instruction && !(elements.get(next) instanceof ConstantInstruction)) return elements.get(next);
            return null;
        }
    }

    private static Predicate<CodeElement> calls(String owner, String name, String type) {
        return element -> element instanceof InvokeInstruction invoke && invoke.owner().asInternalName().equals(owner)
            && invoke.name().equalsString(name) && invoke.type().equalsString(type);
    }

    private static Predicate<CodeElement> field(Opcode opcode, String owner, String name) {
        return element -> element instanceof FieldInstruction field && field.opcode() == opcode
            && field.owner().asInternalName().equals(owner) && field.name().equalsString(name);
    }

    /** An instruction, with the two before it (line numbers skipped; null at the method's start). */
    @FunctionalInterface private interface Window { boolean test(CodeElement second, CodeElement first, CodeElement element); }

    /**
     * A hook on the stores of instance fields (see {@link Site#track} and {@link Site#watch}). The field may be written through
     * a subclass's name or by a class beside it, so a store counts when it is of the class itself or of one of the inventory's.
     */
    private record Mark(boolean wrap, String target, int kind, List<String> own, List<String> inherited, ClassDesc fieldType) {
        boolean stores(CodeElement element, String className) {
            if (!(element instanceof FieldInstruction field) || field.opcode() != Opcode.PUTFIELD) return false;
            String name = field.name().stringValue(), where = field.owner().asInternalName();
            return (own.contains(name) || inherited.contains(name)) && (where.equals(className) || where.startsWith("zombie/inventory/"));
        }

        String problem(String className, ClassModel model) {
            String simple = className.substring(className.lastIndexOf('/') + 1);
            for (String name : own) {
                var field = model.fields().stream().filter(candidate -> candidate.fieldName().equalsString(name)
                    && !candidate.flags().has(AccessFlag.STATIC)).findFirst();
                if (field.isEmpty()) return "expected the field " + simple + "." + name;
                String type = field.get().fieldType().stringValue();
                if (type.equals("J") || type.equals("D")) return "the field " + simple + "." + name + " is a long or a double";
                if (wrap && !type.equals(fieldType.descriptorString())) return "the field " + simple + "." + name + " is " + type;
            }
            int found = 0;
            for (MethodModel method : model.methods()) {
                if (!wrap && (method.methodName().equalsString("<init>") || method.methodName().equalsString("<clinit>"))) continue;
                var code = method.code().orElse(null);
                if (code == null) continue;
                for (CodeElement element : code) if (stores(element, className)) found++;
            }
            return found == 0 ? "expected stores of " + String.join(", ", own) + (inherited.isEmpty() ? "" : " and " + String.join(", ", inherited)) + " in " + simple : null;
        }

        /** The code of every method but the constructors, with the stores signalled. */
        ClassTransform transform(String className) {
            if (wrap) return ClassTransform.transformingMethodBodies((builder, element) -> {
                if (!stores(element, className)) { builder.with(element); return; }
                // this, list -> this, tracked list
                builder.swap();
                builder.dup_x1();
                builder.swap();
                builder.loadConstant(kind);
                builder.invokestatic(HOOKS, "track", MethodTypeDesc.of(ConstantDescs.CD_Object, ConstantDescs.CD_Object, ConstantDescs.CD_Object,
                    ConstantDescs.CD_int));
                builder.checkcast(fieldType);
                builder.with(element);
            });
            return ClassTransform.transformingMethodBodies(method -> !method.methodName().equalsString("<init>")
                && !method.methodName().equalsString("<clinit>"), (builder, element) -> {
                    if (!stores(element, className)) { builder.with(element); return; }
                    // object, value -> object, object, value; the store; object
                    builder.dup2();
                    builder.pop();
                    builder.dup_x2();
                    builder.pop();
                    builder.with(element);
                    builder.invokestatic(HOOKS, target, MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object));
                });
        }
    }

    /**
     * Where a hook goes in one method: before each return, with the return value on the stack; at its start; after
     * the one place where the method asks a square about power for an object ({@code object} gets the square from the
     * object on the stack, and {@code IsoGridSquare.haveElectricity()} follows at once); or before the one instruction
     * {@code at} names.
     */
    private record Site(String method, String type, boolean returns, int argumentSlots, BiConsumer<CodeBuilder, ClassDesc> emit,
            Predicate<CodeElement> object, int kind, Window at, String part, List<String> fields, Edit edit, Mark mark) {
        static Site atReturns(String method, String type, int argumentSlots, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, true, argumentSlots, emit, null, 0, null, null, List.of(), null, null);
        }

        static Site atStart(String method, String type, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, false, 0, emit, null, 0, null, null, List.of(), null, null);
        }

        static Site square(String method, String type, Predicate<CodeElement> object, int kind) {
            return new Site(method, type, false, 0, null, object, kind, null, null, List.of(), null, null);
        }

        static Site before(String method, String type, Window at, BiConsumer<CodeBuilder, ClassDesc> emit) {
            return new Site(method, type, false, 0, emit, null, 0, at, null, List.of(), null, null);
        }

        /** Rewrites each instruction of the method that {@code edit} picks. */
        static Site edit(String method, String type, Edit edit) {
            return new Site(method, type, false, 0, null, null, 0, null, null, List.of(), edit, null);
        }

        /**
         * Every store of the instance field {@code field} (in every method, the constructors' too) hands the list it stores to
         * {@link #track} first, so that the field holds a {@link Tracked} list of the kind. {@code fieldType} is the field's
         * type as the game declares it.
         */
        static Site track(String field, ClassDesc fieldType, int kind) {
            return new Site(field, null, false, 0, null, null, 0, null, "tracked", List.of(), null,
                new Mark(true, field, kind, List.of(field), List.of(), fieldType)).named("tracked");
        }

        /**
         * After every store (outside the constructors) of the fields of the class in {@code own}, and of the fields of its
         * superclass in {@code inherited}, the object stored into is passed to {@code signal}: its weight, or its fluid, may have changed.
         */
        static Site watch(String part, String signal, List<String> own, List<String> inherited) {
            return new Site("writes", null, false, 0, null, null, 0, null, part, List.of(), null,
                new Mark(false, signal, 0, own, inherited, null));
        }

        /** Told apart from another hook in the same method by {@code part}. */
        Site named(String part) { return new Site(method, type, returns, argumentSlots, emit, object, kind, at, part, fields, edit, mark); }

        /** The hook reads these instance fields of the class (int, or {@code name:descriptor}), or calls these methods ({@code name:(...)...}). */
        Site reading(String... names) { return new Site(method, type, returns, argumentSlots, emit, object, kind, at, part, List.of(names), edit, mark); }

        static boolean haveElectricity(CodeElement element) {
            return element instanceof InvokeInstruction invoke && invoke.owner().asInternalName().equals("zombie/iso/IsoGridSquare")
                && invoke.name().equalsString("haveElectricity") && invoke.type().equalsString("()Z");
        }

        boolean matches(MethodModel model) {
            return model.methodName().equalsString(method) && model.methodType().equalsString(type);
        }

        /** {@code IsoGridSquare.haveElectricity}, or {@code Food.updateAge:hours} for one of two hooks in a method. */
        String label(String className) {
            return className.substring(className.lastIndexOf('/') + 1) + "." + method + (part == null ? "" : ":" + part);
        }

        /** Why the hook does not fit the class as it is, or null. */
        String problem(String className, ClassModel model) {
            if (mark != null) return mark.problem(className, model);
            var methods = model.methods().stream().filter(this::matches).toList();
            if (methods.size() != 1) return "expected one " + method + type + ", found " + methods.size();
            var code = methods.get(0).code().orElse(null);
            if (code == null) return method + " has no code";
            // The hook reads the method's arguments at its end: the method must not reuse their slots.
            for (CodeElement element : code)
                if (element instanceof StoreInstruction store && store.slot() < argumentSlots)
                    return method + " reuses its argument slot " + store.slot();
            for (String declared : fields) {
                // "name" is an instance int field; "name:descriptor" an instance field of that type; "name:(...)..." an instance method.
                int colon = declared.indexOf(':');
                String name = colon < 0 ? declared : declared.substring(0, colon), descriptor = colon < 0 ? "I" : declared.substring(colon + 1);
                if (descriptor.startsWith("(")) {
                    if (model.methods().stream().noneMatch(candidate -> candidate.methodName().equalsString(name)
                            && candidate.methodType().equalsString(descriptor) && !candidate.flags().has(AccessFlag.STATIC)))
                        return "expected the method " + className.substring(className.lastIndexOf('/') + 1) + "." + name + descriptor;
                    continue;
                }
                if (model.fields().stream().noneMatch(field -> field.fieldName().equalsString(name)
                        && field.fieldType().equalsString(descriptor) && !field.flags().has(AccessFlag.STATIC)))
                    return "expected the field " + className.substring(className.lastIndexOf('/') + 1) + "." + name;
            }
            if (object != null) {
                int found = 0;
                CodeElement previous = null;
                for (CodeElement element : code) {
                    if (element instanceof LineNumber) continue;
                    if (previous != null && object.test(previous) && haveElectricity(element)) found++;
                    previous = element;
                }
                if (found != 1) return "expected one square power question in " + method + ", found " + found;
            }
            if (at != null) {
                int found = 0;
                CodeElement second = null, first = null;
                for (CodeElement element : code) {
                    if (element instanceof LineNumber) continue;
                    if (at.test(second, first, element)) found++;
                    second = first;
                    first = element;
                }
                if (found != 1) return "expected one place for the hook in " + method + ", found " + found;
            }
            if (edit != null) {
                int found;
                try { found = edit.kindsIn(code.elementList()).length; }
                catch (IllegalArgumentException unfit) { return method + ": " + unfit.getMessage(); }
                if (edit.expected() >= 0 ? found != edit.expected() : found == 0)
                    return "expected " + (edit.expected() >= 0 ? String.valueOf(edit.expected()) : "at least one") + " place(s) for the hook in "
                        + method + ", found " + found;
            }
            return null;
        }

        /** What goes into the class for this hook. */
        ClassTransform classTransform(ClassDesc owner) {
            if (mark != null) {
                String descriptor = owner.descriptorString();
                return mark.transform(descriptor.substring(1, descriptor.length() - 1));
            }
            if (edit == null) return ClassTransform.transformingMethodBodies(this::matches, code(owner));
            // An edit tells its places apart from the code around them, so it reads the method's code first.
            return ClassTransform.transformingMethods(this::matches, (method, element) -> {
                if (!(element instanceof CodeModel original)) { method.with(element); return; }
                int[] kinds = edit.kindsIn(original.elementList());
                method.transformCode(original, CodeTransform.ofStateful(() -> new CodeTransform() {
                    private int next;

                    @Override public void accept(CodeBuilder builder, CodeElement place) {
                        if (edit.matcher().test(place)) edit.emit().emit(builder, place, kinds[next++]);
                        else builder.with(place);
                    }
                }));
            });
        }

        CodeTransform code(ClassDesc owner) {
            if (object != null) return CodeTransform.ofStateful(() -> new CodeTransform() {
                // The instruction that gets the square, held until the next one shows whether the square is asked.
                private CodeElement held;
                private final List<CodeElement> lines = new ArrayList<>();

                @Override public void accept(CodeBuilder builder, CodeElement element) {
                    if (held != null) {
                        if (element instanceof LineNumber) { lines.add(element); return; }
                        if (haveElectricity(element)) {
                            // object -> object, object -> object, square -> object, answer -> answer, object -> hook
                            builder.dup();
                            builder.with(held);
                            lines.forEach(builder::with);
                            builder.with(element);
                            builder.swap();
                            builder.loadConstant(kind);
                            builder.iconst_1();
                            objectPowered(builder);
                            held = null;
                            lines.clear();
                            return;
                        }
                        flush(builder);
                    }
                    if (object.test(element)) held = element;
                    else builder.with(element);
                }

                @Override public void atEnd(CodeBuilder builder) { if (held != null) flush(builder); }

                private void flush(CodeBuilder builder) {
                    builder.with(held);
                    lines.forEach(builder::with);
                    held = null;
                    lines.clear();
                }
            });
            if (at != null) return CodeTransform.ofStateful(() -> new CodeTransform() {
                private CodeElement second, first;

                @Override public void accept(CodeBuilder builder, CodeElement element) {
                    if (!(element instanceof LineNumber)) {
                        if (at.test(second, first, element)) emit.accept(builder, owner);
                        second = first;
                        first = element;
                    }
                    builder.with(element);
                }
            });
            if (returns) return (builder, element) -> {
                if (element instanceof ReturnInstruction) emit.accept(builder, owner);
                builder.with(element);
            };
            return CodeTransform.ofStateful(() -> new CodeTransform() {
                @Override public void atStart(CodeBuilder builder) { emit.accept(builder, owner); }
                @Override public void accept(CodeBuilder builder, CodeElement element) { builder.with(element); }
            });
        }
    }

    /** Sets the handler, replacing an earlier payload's; null when the payload cannot run the API. */
    public static void set(Handler next) {
        synchronized (ApiHooks.class) {
            handler = next;
            expected = false;
            ApiHooks.class.notifyAll();
        }
    }

    /**
     * Every read of {@code usesExternalWaterSource} in the object's water questions passes the flag and the object to
     * {@link #waterPlumbed}. Saving the object keeps the game's own flag.
     */
    private static ClassTransform plumbing(ClassModel model, ClassDesc owner) {
        Predicate<CodeElement> read = element -> element instanceof FieldInstruction field && field.opcode() == Opcode.GETFIELD
            && field.owner().asSymbol().equals(owner) && field.name().equalsString("usesExternalWaterSource");
        Predicate<MethodModel> asks = method -> !PLUMBING_KEPT.contains(method.methodName().stringValue());
        long reads = model.methods().stream().filter(asks).flatMap(method -> method.code().stream())
            .flatMap(code -> code.elementStream()).filter(read).count();
        if (reads == 0) throw new IllegalArgumentException("Expected the water questions to read IsoObject.usesExternalWaterSource");
        return ClassTransform.transformingMethodBodies(asks, (builder, element) -> {
            if (!read.test(element)) { builder.with(element); return; }
            // object -> object, object -> object, flag -> flag, object -> hook
            builder.dup();
            builder.with(element);
            builder.swap();
            builder.invokestatic(HOOKS, "waterPlumbed", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean,
                ConstantDescs.CD_Object));
        });
    }

    /** Sets the power networks, replacing an earlier payload's; null gives every power question to the game alone. */
    public static void setPower(Power next) {
        synchronized (reported) { reported.removeIf(call -> call.group == Group.POWER); }
        power = next;
    }

    /** Put at the end of {@code LuaManager.init()}. */
    public static void luaStarted(Class<?> luaManager) {
        Handler current;
        synchronized (ApiHooks.class) {
            long deadline = System.nanoTime() + HANDLER_WAIT_NANOS;
            try {
                for (long left; handler == null && expected && (left = deadline - System.nanoTime()) > 0;)
                    TimeUnit.NANOSECONDS.timedWait(ApiHooks.class, left);
            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            // Waited once: should the payload never come, later environments do not wait again.
            expected = false;
            current = handler;
        }
        if (current == null) return;
        try { current.luaStarted(luaManager); }
        catch (Throwable problem) { report("luaStarted", problem); }
    }

    /** Sets the water networks, replacing an earlier payload's; null gives every water question to the game alone. */
    public static void setWater(Water next) {
        synchronized (reported) { reported.removeIf(call -> call.group == Group.WATER); }
        water = next;
    }

    /** Put after each read of {@code IsoObject.usesExternalWaterSource} in the object's water questions. */
    public static boolean waterPlumbed(boolean vanilla, Object fixture) {
        if (vanilla) return true;
        Water current = water;
        if (current == null) return false;
        try { return current.plumbed(false, fixture); }
        catch (Throwable problem) { reportOnce(Call.WATER_PLUMBED, problem); return false; }
    }

    /** Put before each return of {@code IsoObject.checkExternalFluidSource()}. */
    public static Object waterSource(Object vanilla, Object fixture) {
        Water current = water;
        if (current == null) return vanilla;
        try { return current.source(vanilla, fixture); }
        catch (Throwable problem) { reportOnce(Call.WATER_SOURCE, problem); return vanilla; }
    }

    /** Put at the start of {@code IsoObject.createSampleAndPurifyWater(source, amount)}: a sample it gives is returned at once. */
    public static Object waterSample(Object fixture, Object source, float amount) {
        Water current = water;
        if (current == null) return null;
        try { return current.sample(fixture, source, amount); }
        catch (Throwable problem) { reportOnce(Call.WATER_SAMPLE, problem); return null; }
    }

    /** Put before each return of {@code IsoObject.isTaintedWater()}. */
    public static boolean waterTainted(boolean vanilla, Object fixture) {
        if (vanilla) return true;
        Water current = water;
        if (current == null) return false;
        try { return current.tainted(false, fixture); }
        catch (Throwable problem) { reportOnce(Call.WATER_TAINTED, problem); return false; }
    }

    /** Whether the game's purification of a fixture's water has its hooks: IsoObject loaded with them. */
    public static boolean waterPurifyHooked() { return purifyHooked; }

    /** Put before each return of {@code IsoGridSquare.haveElectricity()}. */
    public static boolean squarePowered(boolean vanilla, int x, int y, int z) {
        if (vanilla) return true;
        Power current = power;
        if (current == null) return false;
        try { return current.square(x, y, z); }
        catch (Throwable problem) { reportOnce(Call.SQUARE, problem); return false; }
    }

    /** Put before each return of the object questions; see {@link Power#object}. */
    public static boolean objectPowered(boolean vanilla, Object object, int kind, boolean generators) {
        Power current = power;
        if (current == null) return vanilla;
        try { return current.object(vanilla, object, kind, generators); }
        catch (Throwable problem) { reportOnce(Call.OBJECT, problem); return vanilla; }
    }

    /** Put at the start of {@code IsoGenerator.setSurroundingElectricity()}: true returns at once. */
    public static boolean generatorSurrounding(Object generator) {
        Power current = power;
        if (current == null) return false;
        try { return current.generator(generator); }
        catch (Throwable problem) { reportOnce(Call.GENERATOR, problem); return false; }
    }

    /** Put at the start of {@code IsoGenerator.updateGenerator(square)}. */
    public static void consumerChanged(Object square) {
        Power current = power;
        if (current == null) return;
        try { current.consumerChanged(square); }
        catch (Throwable problem) { reportOnce(Call.CONSUMER_CHANGED, problem); }
    }

    /** Sets the formulas, replacing an earlier payload's; null gives every formula question to the game alone. */
    public static void setFormulas(Formulas next) {
        synchronized (reported) { reported.removeIf(call -> call.group == Group.FORMULAS); }
        formulas = next;
    }

    /** Put before each return of {@code IsoGameCharacter.getClothingDiscomfortModifier()}. */
    public static float discomfort(float vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.discomfort(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.DISCOMFORT, problem); return vanilla; }
    }

    /** Put at the start of {@code IsoGameCharacter.addStiffness(part, amount)}: the amount to add instead. */
    public static float stiffness(float amount, Object character) {
        Formulas current = formulas;
        if (current == null) return amount;
        try { return current.stiffness(amount, character); }
        catch (Throwable problem) { reportOnce(Call.STIFFNESS, problem); return amount; }
    }

    /** Put before each return of {@code IsoGameCharacter.getFatiqueMultiplier()}. */
    public static double fatigue(double vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.fatigue(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.FATIGUE, problem); return vanilla; }
    }

    /** Put at the start of {@code Stats.add(stat, delta)}: the change to make instead. */
    public static float statDelta(Object stats, Object stat, float delta) {
        Formulas current = formulas;
        if (current == null) return delta;
        try { return current.statDelta(delta, stats, stat); }
        catch (Throwable problem) { reportOnce(Call.STAT_DELTA, problem); return delta; }
    }

    /** Put at the start of {@code IsoGameCharacter.getInventoryWeight()}: NaN for the game's own walk. */
    public static float inventoryWeight(Object character) {
        Formulas current = formulas;
        if (current == null) return Float.NaN;
        try { return current.inventoryWeight(character); }
        catch (Throwable problem) { reportOnce(Call.INVENTORY_WEIGHT, problem); return Float.NaN; }
    }

    /**
     * Put where the game makes the list of a container's items, or of a character's worn items: the list it made, as a
     * {@link Tracked} one (the list the game goes on with).
     */
    public static Object track(Object owner, Object list, int kind) {
        if (list instanceof Tracked) return list;
        return new Tracked(kind, owner, (Collection<?>)list);
    }

    /** Called by a {@link Tracked} list after it took an item. */
    static void itemAdded(Tracked list, Object item) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.itemAdded(list, item); }
        catch (Throwable problem) { reportOnce(Call.ITEM_ADDED, problem); }
    }

    /** Called by a {@link Tracked} list after an item came out. */
    static void itemRemoved(Tracked list, Object item) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.itemRemoved(list, item); }
        catch (Throwable problem) { reportOnce(Call.ITEM_REMOVED, problem); }
    }

    /** Called by a {@link Tracked} list after it was emptied. */
    static void listCleared(Tracked list) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.listCleared(list); }
        catch (Throwable problem) { reportOnce(Call.LIST_CLEARED, problem); }
    }

    /** Called by a {@link Tracked} list after a change it cannot name item by item. */
    static void listChanged(Tracked list) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.listChanged(list); }
        catch (Throwable problem) { reportOnce(Call.LIST_CHANGED, problem); }
    }

    /** Put at the start of {@code ItemContainer.setItems(list)} and {@code emptyIt()}. */
    public static void itemsReplacing(Object container) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.itemsReplacing(container); }
        catch (Throwable problem) { reportOnce(Call.ITEMS_REPLACING, problem); }
    }

    /** Put after each store of a field that an item's weight reads. */
    public static void weightChanged(Object item) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.weightChanged(item); }
        catch (Throwable problem) { reportOnce(Call.WEIGHT_CHANGED, problem); }
    }

    /** Put after each store of a field that a fluid container's amount is read from. */
    public static void fluidChanged(Object fluid) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.fluidChanged(fluid); }
        catch (Throwable problem) { reportOnce(Call.FLUID_CHANGED, problem); }
    }

    /** Put after each read of the item's weight in {@code ItemContainer.hasRoomFor(character, item)}. */
    public static float incoming(Object item, float vanilla, Object container, int viaBag) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.incoming(item, vanilla, container, viaBag != 0); }
        catch (Throwable problem) { reportOnce(Call.INCOMING, problem); return vanilla; }
    }

    /** Put before each return of {@code IsoGameCharacter.getMaxWeight()}. */
    public static int maxWeight(int vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.maxWeight(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.MAX_WEIGHT, problem); return vanilla; }
    }

    /** Put before each return of {@code ItemContainer.getEffectiveCapacity(character)}. */
    public static int effectiveCapacity(int vanilla, Object container, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.effectiveCapacity(vanilla, container, character); }
        catch (Throwable problem) { reportOnce(Call.EFFECTIVE_CAPACITY, problem); return vanilla; }
    }

    /** Put before each return of {@code ItemContainer.getCapacity()}. */
    public static int capacity(int vanilla, Object container) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.capacity(vanilla, container); }
        catch (Throwable problem) { reportOnce(Call.CAPACITY, problem); return vanilla; }
    }

    /** Put before each return of {@code InventoryContainer.getCapacity()}. */
    public static int bagCapacity(int vanilla, Object bag) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.bagCapacity(vanilla, bag); }
        catch (Throwable problem) { reportOnce(Call.BAG_CAPACITY, problem); return vanilla; }
    }

    /** Put before each return of {@code InventoryContainer.getEffectiveCapacity(character)}. */
    public static int bagEffectiveCapacity(int vanilla, Object bag, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.bagEffectiveCapacity(vanilla, bag, character); }
        catch (Throwable problem) { reportOnce(Call.BAG_EFFECTIVE_CAPACITY, problem); return vanilla; }
    }

    /** Put after each call of {@code ItemContainer.getCapacityWeight()} that asks how heavily a character is loaded. */
    public static float overload(Object container, float weight) {
        Formulas current = formulas;
        if (current == null) return weight;
        try { return current.overload(container, weight); }
        catch (Throwable problem) { reportOnce(Call.OVERLOAD, problem); return weight; }
    }

    /** Put before the store of {@code IsoGameCharacter.fullSpeedMod} in {@code calculateBaseSpeed()}. */
    public static float runPenalty(float vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.runPenalty(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.RUN_PENALTY, problem); return vanilla; }
    }

    /** Put after the read of {@code IsoGameCharacter.combatSpeedModifier} in {@code calculateCombatSpeed()}. */
    public static float combatPenalty(float vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.combatPenalty(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.COMBAT_PENALTY, problem); return vanilla; }
    }

    /** Put before each return of {@code ItemPickerJava.getActualSpawnChance}. */
    public static float lootChance(float vanilla) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.lootChance(vanilla); }
        catch (Throwable problem) { reportOnce(Call.LOOT_CHANCE, problem); return vanilla; }
    }

    /** Put after the read of {@code ItemPickerJava.ammoLootModifier} in {@code getLootModifierFromType}. */
    public static float lootAmmo(float vanilla) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.lootAmmo(vanilla); }
        catch (Throwable problem) { reportOnce(Call.LOOT_AMMO, problem); return vanilla; }
    }

    /** Put before each return of {@code LightingJNI.getLumaInverted}. */
    public static float darkness(float vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.darkness(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.DARKNESS, problem); return vanilla; }
    }

    /** Put at the return of {@code ShaderUnit.loadShaderFile}: the screen shader gets night sight's step. */
    public static String shaderSource(String source, String fileName) {
        try { return ScreenShader.patch(source, fileName); }
        catch (Throwable problem) { reportOnce(Call.NIGHT_SIGHT, problem); return source; }
    }

    /** Put at the return of {@code WeatherShader.onCompileSuccess}: its program. */
    public static void nightSightProgram(int program) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.nightSightProgram(program); }
        catch (Throwable problem) { reportOnce(Call.NIGHT_SIGHT, problem); }
    }

    /** Put at the start of {@code WeatherShader.startMainThread}. */
    public static void nightSightFrame(int playerIndex) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.nightSightFrame(playerIndex); }
        catch (Throwable problem) { reportOnce(Call.NIGHT_SIGHT, problem); }
    }

    /** Put before the return of {@code WeatherShader.startRenderThread}, whose program is bound. */
    public static void nightSightDraw(int program) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.nightSightDraw(program); }
        catch (Throwable problem) { reportOnce(Call.NIGHT_SIGHT, problem); }
    }

    /**
     * Put after each call of {@code LightingJNI.getSquareLighting} in the lighting's reads, with its arguments (the
     * lighting's z is the floor + 32): whether it handed anything, as it was.
     */
    public static boolean squareLit(boolean lit, int playerIndex, int x, int y, int z, int[] ints) {
        if (!lit) return false;
        Formulas current = formulas;
        if (current == null) return true;
        try { current.squareLit(playerIndex, x, y, z - 32, ints); }
        catch (Throwable problem) { reportOnce(Call.NIGHT_SIGHT, problem); }
        return true;
    }

    /**
     * Put after each call of {@code LightingJNI.getSquareDirty} in the lighting's reads, with its arguments (the
     * lighting's z is the floor + 32): whether the square is read again.
     */
    public static boolean squareDirty(boolean dirty, int playerIndex, int x, int y, int z) {
        if (dirty) return true;
        Formulas current = formulas;
        if (current == null) return false;
        try { return current.squareStale(playerIndex, x, y, z - 32); }
        catch (Throwable problem) { reportOnce(Call.NIGHT_SIGHT, problem); return false; }
    }

    /** Put before each return of {@code FBORenderCell.sanitizeLightInfo}. */
    public static Object objectLight(Object info, int playerIndex) {
        Formulas current = formulas;
        if (current == null) return info;
        try { return current.objectLight(info, playerIndex); }
        catch (Throwable problem) { reportOnce(Call.NIGHT_SIGHT, problem); return info; }
    }

    // The call that hands a square's lighting into an int[]: its arguments are kept, the call made, and squareLit given
    // them with the answer.
    private static Predicate<CodeElement> squareLightingCall() { return calls("zombie/iso/LightingJNI", "getSquareLighting", "(IIII[I)Z"); }

    // The lighting's answer whether a square changed: its arguments are kept, the call made, and squareDirty given them
    // with the answer.
    private static Predicate<CodeElement> squareDirtyCall() { return calls("zombie/iso/LightingJNI", "getSquareDirty", "(IIII)Z"); }

    private static void squareDirtyCheck(CodeBuilder code, CodeElement call, int kind) {
        int z = code.allocateLocal(TypeKind.INT), y = code.allocateLocal(TypeKind.INT), x = code.allocateLocal(TypeKind.INT);
        int player = code.allocateLocal(TypeKind.INT);
        // player, x, y, z -> player, x, y, z
        code.istore(z);
        code.istore(y);
        code.istore(x);
        code.dup();
        code.istore(player);
        code.iload(x);
        code.iload(y);
        code.iload(z);
        code.with(call);
        code.iload(player);
        code.iload(x);
        code.iload(y);
        code.iload(z);
        code.invokestatic(HOOKS, "squareDirty", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean, ConstantDescs.CD_int,
            ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int));
    }

    private static void squareLighting(CodeBuilder code, CodeElement call, int kind) {
        int ints = code.allocateLocal(TypeKind.REFERENCE), z = code.allocateLocal(TypeKind.INT), y = code.allocateLocal(TypeKind.INT);
        int x = code.allocateLocal(TypeKind.INT), player = code.allocateLocal(TypeKind.INT);
        // player, x, y, z, ints -> player
        code.astore(ints);
        code.istore(z);
        code.istore(y);
        code.istore(x);
        code.dup();
        code.istore(player);
        code.iload(x);
        code.iload(y);
        code.iload(z);
        code.aload(ints);
        code.with(call);
        code.iload(player);
        code.iload(x);
        code.iload(y);
        code.iload(z);
        code.aload(ints);
        code.invokestatic(HOOKS, "squareLit", MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_boolean, ConstantDescs.CD_int,
            ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int.arrayType()));
    }

    /** Put before {@code calculateVisionCone} multiplies the degrees by what the worn items allow. */
    public static float coneAdd(Object character, float degrees) {
        Formulas current = formulas;
        if (current == null) return degrees;
        try { return current.coneAdd(character, degrees); }
        catch (Throwable problem) { reportOnce(Call.CONE_ADD, problem); return degrees; }
    }

    /** Put at the start of {@code IsoGameCharacter.DoLand}: the speed to land with. */
    public static float landing(float speed, Object character) {
        Formulas current = formulas;
        if (current == null) return speed;
        try { return current.landing(speed, character); }
        catch (Throwable problem) { reportOnce(Call.LANDING, problem); return speed; }
    }

    /** Put after the call of {@code FallDamage.getImpactIsoSpeed()} in {@code handleLandingImpact}. */
    public static float impact(float speed, Object character) {
        Formulas current = formulas;
        if (current == null) return speed;
        try { return current.impact(speed, character); }
        catch (Throwable problem) { reportOnce(Call.IMPACT, problem); return speed; }
    }

    /** Put before each return of {@code IsoTree.getSlowFactor}. */
    public static float treeSlow(float vanilla, Object mover) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.treeSlow(vanilla, mover); }
        catch (Throwable problem) { reportOnce(Call.TREE_SLOW, problem); return vanilla; }
    }

    /** Put before each return of {@code IsoPlayer.calculateInTreesSpeed}. */
    public static float treeAnimation(float vanilla, Object player) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.treeAnimation(vanilla, player); }
        catch (Throwable problem) { reportOnce(Call.TREE_ANIMATION, problem); return vanilla; }
    }

    /** Put at the start of {@code IsoGameCharacter.damageWhileInTrees}: false returns at once. */
    public static boolean treeScratch(Object character) {
        Formulas current = formulas;
        if (current == null) return true;
        try { return current.treeScratch(character); }
        catch (Throwable problem) { reportOnce(Call.TREE_SCRATCH, problem); return true; }
    }

    /** Put before each return of {@code IsoPlayer.getDeferredMovement(vector, boolean)}: what the vector is scaled by (1 leaves it). */
    public static float walk(Object character) {
        Formulas current = formulas;
        if (current == null) return 1f;
        try { return current.walk(character); }
        catch (Throwable problem) { reportOnce(Call.WALK, problem); return 1f; }
    }

    /** Put before each return of {@code Thermoregulator.getCatchAColdDelta}. */
    public static float cold(float vanilla, Object player) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.cold(vanilla, player); }
        catch (Throwable problem) { reportOnce(Call.COLD, problem); return vanilla; }
    }

    /** Put before each return of {@code CorpseCount.getCorpseCount(character)}. */
    public static int corpseCount(int vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.corpseCount(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.CORPSE_COUNT, problem); return vanilla; }
    }

    /** Put before each return of {@code BodyDamage.GetBaseCorpseSickness}. */
    public static float corpseSickness(float vanilla, Object character) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.corpseSickness(vanilla, character); }
        catch (Throwable problem) { reportOnce(Call.CORPSE_SICKNESS, problem); return vanilla; }
    }

    /** Put at the start of {@code IsoGameCharacter.addHole(part, boolean)}: false returns false at once. */
    public static boolean hole(Object character) {
        Formulas current = formulas;
        if (current == null) return true;
        try { return current.hole(character); }
        catch (Throwable problem) { reportOnce(Call.HOLE, problem); return true; }
    }

    /** Put at the start of {@code BodyPart.generateZombieInfection}: false returns at once. */
    public static boolean wound(Object character) {
        Formulas current = formulas;
        if (current == null) return true;
        try { return current.wound(character); }
        catch (Throwable problem) { reportOnce(Call.WOUND, problem); return true; }
    }

    /** Put just before ({@code after} 0) and just after (1) the call of {@code SetBitten(index, true)} a zombie's bite makes. */
    public static void bite(Object bodyDamage, int index, int after) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.bite(bodyDamage, index, after != 0); }
        catch (Throwable problem) { reportOnce(Call.BITE, problem); }
    }

    /** Put before each return of {@code IsoObject.couldBePoweredByGenerator}. */
    public static boolean machine(boolean vanilla, Object object) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.machine(vanilla, object); }
        catch (Throwable problem) { reportOnce(Call.MACHINE, problem); return vanilla; }
    }

    /** Put before each return of {@code IsoObject.getGeneratorPowerConsumption}. */
    public static float machineLoad(float vanilla, Object object) {
        Formulas current = formulas;
        if (current == null) return vanilla;
        try { return current.machineLoad(vanilla, object); }
        catch (Throwable problem) { reportOnce(Call.MACHINE_LOAD, problem); return vanilla; }
    }

    /** Put after the call of {@code IsoSpriteInstance.update()} in {@code IsoObject.renderAttachedSprites}: the instance and its object. */
    public static void attachedAnim(Object instance, Object object) {
        Formulas current = formulas;
        if (current == null) return;
        try { current.attachedAnim(instance, object); }
        catch (Throwable problem) { reportOnce(Call.ATTACHED_ANIM, problem); }
    }

    /** Put before each return of {@code IsoObject.isAnimating()}. */
    public static boolean animating(boolean vanilla, Object object) {
        if (vanilla) return true;
        Formulas current = formulas;
        if (current == null) return false;
        try { return current.animating(false, object); }
        catch (Throwable problem) { reportOnce(Call.ANIMATING, problem); return false; }
    }

    /** Put at the start of {@code IsoGenerator.update()}. */
    public static void generatorUpdate(Object generator) {
        Power current = power;
        if (current == null) return;
        try { current.generatorUpdate(generator); }
        catch (Throwable problem) { reportOnce(Call.GENERATOR_UPDATE, problem); }
    }

    /** Put before {@code Food.updateAge} reads the food's rot speed, with the hours it ages over on the stack. */
    public static double foodHours(double vanilla, Object food) {
        Power current = power;
        if (current == null) return vanilla;
        try { return current.foodHours(vanilla, food); }
        catch (Throwable problem) { reportOnce(Call.FOOD_HOURS, problem); return vanilla; }
    }

    /** Sets the moodles, replacing an earlier payload's; null gives every moodle question to the game alone. */
    public static void setMoodles(Moodles next) {
        synchronized (reported) { reported.removeIf(call -> call.group == Group.MOODLES); }
        moodles = next;
    }

    /** Put at the start of {@code Moodle.Update()}: the level to update the moodle to, or -1 for the game's own update. */
    public static int moodleLevel(Object type, Object character) {
        Moodles current = moodles;
        if (current == null) return -1;
        try { return current.level(type, character); }
        catch (Throwable problem) { reportOnce(Call.MOODLE_LEVEL, problem); return -1; }
    }

    /** Put before each return of {@code Moodles.GoodBadNeutral(type)}. */
    public static int moodleKind(int vanilla, Object type) {
        Moodles current = moodles;
        if (current == null) return vanilla;
        try { return current.kind(vanilla, type); }
        catch (Throwable problem) { reportOnce(Call.MOODLE_KIND, problem); return vanilla; }
    }

    /**
     * Put after {@code MoodlesUI.render} asks its texture set for a type's picture: the set's picture, or the API's for a type the
     * set has none for. With none at all the game's column would fail to draw that moodle, and go on failing every frame while
     * the game is paused (no update takes its level back to 0), leaving the moodles below it undrawn: so for a type no one has a
     * picture for (the API failed, is being replaced, or no longer knows the type) the set's empty frame is drawn instead.
     */
    public static Object moodlePicture(Object set, Object type, Object vanilla, Object ui) {
        if (vanilla != null) return vanilla;
        Moodles current = moodles;
        Object picture = null;
        if (current != null) {
            try { picture = current.picture(set, type, ui); }
            catch (Throwable problem) { reportOnce(Call.MOODLE_PICTURE, problem); }
        }
        return picture != null ? picture : frame(set);
    }

    /** Sets the text, replacing an earlier payload's; null draws none. */
    public static void setText(Text next) {
        synchronized (reported) { reported.removeIf(call -> call.group == Group.TEXT); }
        text = next;
    }

    /** Put in {@code UIManager.render}, once the interface's windows are drawn: the text mods show is drawn over them. */
    public static void uiDrawn() {
        Text current = text;
        if (current == null) return;
        try { current.draw(); }
        catch (Throwable problem) { reportOnce(Call.TEXT, problem); }
    }

    /** Sets what hears the sounds zombies make, replacing an earlier payload's; null while nobody listens (the hooks then return at once). */
    public static void setZombieSounds(ZombieSounds next) {
        synchronized (reported) { reported.removeIf(call -> call.group == Group.ZOMBIE_SOUNDS); }
        zombieSounds = next;
    }

    /** Put before the store of the new state in {@code ParameterZombieState.setState}: the state changes. */
    public static void zombieState(Object to, Object zombie, Object from) {
        ZombieSounds current = zombieSounds;
        if (current == null) return;
        try { current.state(zombie, from, to); }
        catch (Throwable problem) { reportOnce(Call.ZOMBIE_STATE, problem); }
    }

    /** Put before the call of {@code playVocals} in {@code ZombieVocalsManager$Slot.playSound}. */
    public static void zombieVoice(Object zombie) {
        ZombieSounds current = zombieSounds;
        if (current == null) return;
        try { current.voice(zombie); }
        catch (Throwable problem) { reportOnce(Call.ZOMBIE_VOICE, problem); }
    }

    /** Put at the start of {@code IsoZombie.handleLandingImpact}. */
    public static void zombieLanded(Object zombie) {
        ZombieSounds current = zombieSounds;
        if (current == null) return;
        try { current.landed(zombie); }
        catch (Throwable problem) { reportOnce(Call.ZOMBIE_LANDED, problem); }
    }

    // MoodleTextureSet.getBorder(), found once, for the rare path where no picture is known.
    private static volatile Method border;
    private static final Object[] NO_ARGUMENTS = {};

    private static Object frame(Object set) {
        try {
            Method found = border;
            if (found == null || found.getDeclaringClass() != set.getClass()) border = found = set.getClass().getMethod("getBorder");
            return found.invoke(set, NO_ARGUMENTS);
        } catch (ReflectiveOperationException | RuntimeException | LinkageError unreadable) { return null; }
    }

    private static void reportOnce(Call call, Throwable problem) {
        synchronized (reported) { if (!reported.add(call)) return; }
        report(call.label, problem);
    }

    // To the game's console log; the game goes on as if the hook were not there.
    private static void report(String where, Throwable problem) { System.err.println("[PzTools API] " + where + ": " + problem); }

    /**
     * Night sight's step in the game's screen shader ({@code media/shaders/screen.frag}, the pass the whole world is drawn
     * through): the source the game loads gets its uniforms and functions before {@code textureBicubic}, the sampling the
     * pass reads the world with on every path (the stock one, and the ones PZ Optimization's colour grading and its other
     * passes put in, which also read it), which returns its colour through the step; the pass's own reads of single texels
     * of the world ({@code texture2D(DIFFUSE, ...)}, the blur's) are made through it too. The night vision goggles' path
     * is left alone. At night sight off the step gives the colour back as it is. A source without the places the step goes
     * (a mod's own shader, a newer game) is loaded as it is, and night sight then shows no screen pass.
     */
    static final class ScreenShader {
        static final String UNIFORM = "PZT_NightSight";
        private static final String FILE = "screen.frag";
        private static final String SAMPLING = "vec4 textureBicubic(";
        private static final String GOGGLES = "uniform float NightVisionGoggles;";
        private static final java.util.regex.Pattern TEXEL = java.util.regex.Pattern.compile("texture2D\\(\\s*DIFFUSE\\s*,");

        /**
         * What the eye saw without night sight keeps its colour and what it adds is a cold grey, as the eye's rods see: a
         * pixel's colour is kept by its square's share (PZT_SightLamps, by the floor under the pixel, found from PZT_SightU
         * and V; beyond it, PZT_SightKeep), and dark tones are lifted, the darker the more (a gamma, by PZT_NightSight), in
         * grey too, but for the light a light source gives (its second channel). The values are the last set's (red, green)
         * and the newest's (blue, alpha), PZT_SightBlend of the way from the one to the other. A square raised to more
         * light than the least shown (PZT_SightShade of it) is taken down to it first, its colour kept against it.
         */
        static final String STEP = """

            uniform float PZT_NightSight;
            uniform float PZT_SightOn;
            uniform float PZT_SightKeep;
            uniform sampler2D PZT_SightLamps;
            uniform vec3 PZT_SightU;
            uniform vec3 PZT_SightV;
            uniform float PZT_SightLift;
            uniform float PZT_SightBlend;
            uniform float PZT_SightShade;

            vec3 pztNightSight(in vec3 seen) {
            	if (PZT_SightOn <= 0.0 || NightVisionGoggles >= 0.5) return seen;
            	vec3 at = vec3(gl_FragCoord.xy, 1.0);
            	vec2 uv = vec2(dot(PZT_SightU, at), dot(PZT_SightV, at));
            	vec2 square = vec2(clamp(PZT_SightKeep, 0.0, 1.0), 0.0);
            	if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) {
            		vec4 both = texture(PZT_SightLamps, uv);
            		square = mix(both.rg, both.ba, clamp(PZT_SightBlend, 0.0, 1.0));
            	}
            	float least = clamp(PZT_SightShade, 0.0, 1.0);
            	vec3 col = seen * max(square.x, least);
            	square.x = least > 0.0 ? min(square.x / least, 1.0) : 1.0;
            	float l = dot(col, vec3(0.299, 0.587, 0.114));
            	float s = clamp(PZT_NightSight, 0.0, 1.0);
            	float lifted = s > 0.0 ? mix(pow(max(l, 0.0), 1.0 - clamp(PZT_SightLift, 0.0, 1.0) * s), l, square.y) : l;
            	vec3 kept = col * square.x;
            	float grey = max(lifted - dot(kept, vec3(0.299, 0.587, 0.114)), 0.0);
            	return clamp(kept + grey * vec3(0.84, 0.92, 1.08), 0.0, 1.0);
            }

            vec4 pztDiffuse(in vec2 uv) {
            	vec4 texel = texture(DIFFUSE, uv);
            	return vec4(pztNightSight(texel.rgb), texel.a);
            }

            """;

        private ScreenShader() { }

        /** The source with night sight's step, or the source as it is (another file, already patched, or no place for it). */
        static String patch(String source, String fileName) {
            if (source == null || fileName == null || !fileName.replace('\\', '/').endsWith(FILE) || source.contains(UNIFORM)
                || !source.contains(GOGGLES)) return source;
            int sampling = source.indexOf(SAMPLING);
            if (sampling < 0) return source;
            int body = source.indexOf('{', sampling);
            int end = body < 0 ? -1 : closing(source, body);
            if (end < 0) return source;
            int ret = source.lastIndexOf("return ", end);
            int semicolon = ret < body ? -1 : source.indexOf(';', ret);
            if (semicolon < 0 || semicolon > end) return source;
            String value = source.substring(ret + "return ".length(), semicolon);
            String sampled = source.substring(0, ret) + "vec4 pztSampled = " + value + ";\n\treturn vec4(pztNightSight(pztSampled.rgb), pztSampled.a);"
                + source.substring(semicolon + 1);
            String head = sampled.substring(0, sampling), rest = sampled.substring(sampling);
            return head + STEP + TEXEL.matcher(rest).replaceAll("pztDiffuse(");
        }

        /** The index of the brace that closes the one at {@code open}, or -1. */
        private static int closing(String source, int open) {
            int depth = 0;
            for (int i = open; i < source.length(); i++) {
                char c = source.charAt(i);
                if (c == '{') depth++;
                else if (c == '}' && --depth == 0) return i;
            }
            return -1;
        }
    }
}
