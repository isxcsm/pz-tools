package pztools.extensions.seamless.b4220;

import pztools.extensions.api.*;
import pztools.extensions.seamless.SeamlessSaveProvider;
import java.lang.instrument.*;
import java.lang.reflect.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

/** First executable adapter: no forced thumbnail redraw, original world save, then acknowledged DB drains. */
public final class Build4220Adapter implements SeamlessSaveProvider.GameAdapter {
    private static final Map<String, String> GAME_CLASSES = Map.of(
        "zombie/GameWindow", "21666fb045fe1bd49d2fabdf196618952b5eda72985be49750c796c7e812087a",
        "zombie/savefile/PlayerDB", "e70b081832b1d77b10df9d774a82d3062c306c2b9b3bef8b8f6f8bf87a53aea8",
        "zombie/vehicles/VehiclesDB2", "f908628f3a94a018cc4666ef14bdb01326eeb90ca27f55d7b744d215a7a9f9ba",
        "zombie/core/logger/ExceptionLogger", "80d6a61b482409fdce589b324cc70d31901ad0278acebe94844c27a5084ed3f4",
        "zombie/iso/IsoCell", "6f55ff3bae344124c9ec0a29fa93198190901da04574e9b9cafa44b9aa962b1f",
        "zombie/iso/IsoChunk", "68431ace471b30c842ff7c2a6e706d8ba48d7a84ae07f876484153c0d62a794b",
        "zombie/iso/IsoChunkMap", "8a640e4756d98f6cafd77e6d36a7b9042ea844744af3f0bb2cda257726d3b61c",
        "zombie/vehicles/VirtualVehicleManager", "91849135296db0246ec51fd5eb3e3e890f4436c78b48dcc37e1ff573cdbd271e");
    private final SaveSignals signals = new SaveSignals();
    private final AtomicReference<Throwable> transformationFailure = new AtomicReference<>();
    private Method save, allowPlayers, getPlayers, updatePlayers, updateVehicles;
    private Field vehicles;
    private volatile boolean initialized;
    private ClassFileTransformer transformer;
    @Override public SaveProvider.Support initialize(Instrumentation instrumentation, ClassLoader loader) throws Exception {
        if (initialized) return new SaveProvider.Support(transformationFailure.get() == null, "game-code-changed");
        if (instrumentation == null || Runtime.version().feature() != 25 || !instrumentation.isRetransformClassesSupported())
            return new SaveProvider.Support(false, "unsupported-runtime");
        for (var entry : GAME_CLASSES.entrySet()) {
            try (var input = loader.getResourceAsStream(entry.getKey() + ".class")) {
                if (input == null) return new SaveProvider.Support(false, "unsupported-game-build");
                byte[] bytes = input.readNBytes(4 * 1024 * 1024 + 1);
                String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
                if (!digest.equals(entry.getValue())) return new SaveProvider.Support(false, "unsupported-game-build");
            }
        }
        if (Class.forName(GameHooks.class.getName(), false, loader) != GameHooks.class)
            return new SaveProvider.Support(false, "unsupported-game-loader");
        Class<?> window = Class.forName("zombie.GameWindow", false, loader);
        Class<?> playerDb = Class.forName("zombie.savefile.PlayerDB", false, loader);
        Class<?> vehicleDb = Class.forName("zombie.vehicles.VehiclesDB2", false, loader);
        Class<?> logger = Class.forName("zombie.core.logger.ExceptionLogger", false, loader);
        save = window.getMethod("save", boolean.class);
        allowPlayers = playerDb.getMethod("isAllow"); getPlayers = playerDb.getMethod("getInstance");
        updatePlayers = playerDb.getMethod("updateMain"); updateVehicles = vehicleDb.getMethod("updateMain");
        vehicles = vehicleDb.getField("instance");
        Class<?>[] targets = { window, playerDb, vehicleDb, logger };
        for (Class<?> type : targets) if (!instrumentation.isModifiableClass(type))
            return new SaveProvider.Support(false, "unmodifiable-game-class");
        Set<Class<?>> selected = Set.of(targets);
        Set<Class<?>> transformed = ConcurrentHashMap.newKeySet();
        transformer = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader owner, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (owner != loader || !selected.contains(type)) return null;
                try {
                    byte[] result = SaveBytecode.transform(name, bytes, loader);
                    transformed.add(type);
                    return result;
                } catch (Throwable failure) {
                    transformationFailure.compareAndSet(null, failure);
                    return null;
                }
            }
        };
        signals.register();
        instrumentation.addTransformer(transformer, true);
        try {
            instrumentation.retransformClasses(targets);
            if (transformed.size() != targets.length || transformationFailure.get() != null)
                throw new IllegalStateException("Incomplete save interception", transformationFailure.get());
            initialized = true;
            return new SaveProvider.Support(true, null);
        } catch (Exception failure) {
            instrumentation.removeTransformer(transformer);
            signals.unregister(); // Partially installed guards are inert; ordinary saving is untouched.
            instrumentation.retransformClasses(targets);
            return new SaveProvider.Support(false, "unsupported-hook-layout");
        }
    }
    @Override public SaveProvider.Support inspect(SaveProvider.Context context) {
        context.requireGameThread();
        return new SaveProvider.Support(initialized && transformationFailure.get() == null,
            initialized ? "game-code-changed" : "adapter-not-initialized");
    }
    @Override public SaveProvider.PreparedSave capture(SaveProvider.Context context, long maximumBytes) throws Exception {
        context.requireGameThread();
        if (!inspect(context).supported()) throw new IllegalStateException("Save adapter unavailable");
        boolean includePlayers = (boolean)allowPlayers.invoke(null);
        Object playerStore = includePlayers ? getPlayers.invoke(null) : null;
        Object vehicleStore = Objects.requireNonNull(vehicles.get(null), "Vehicle store unavailable");
        var batch = signals.begin(context, includePlayers);
        try {
            // This intentionally remains on the game thread. OnSave, loaded/virtual vehicles,
            // chunk serialization and native world saving are NOT replaced by a partial imitation.
            save.invoke(null, true);
            // savePlayers() only sets a flag in B42.20. Capture its queued bytes in this same game tick.
            if (includePlayers) updatePlayers.invoke(playerStore);
            updateVehicles.invoke(vehicleStore);
        } catch (InvocationTargetException failure) {
            batch.fail(failure.getCause());
        } catch (Exception failure) {
            batch.fail(failure);
        } finally {
            // A drain that began before this publication cannot satisfy this request's fence.
            batch.arm();
        }
        return batch;
    }
}
