package zombie.gameStates;

import java.nio.file.*;

public final class IngameState {
    /** Leaving for the main menu as the game does, in one frame: saved from this state's update, unloaded as it ends. */
    public void updateInternal(Path signals) throws Exception {
        zombie.GameWindow.save(true);
        exit(signals);
        zombie.GameWindow.states.current = new MainScreenState();
    }

    // Unloading the world and reloading the mods.
    public void exit(Path signals) throws InterruptedException {
        while (Files.exists(signals.resolve("hold-exit"))) Thread.sleep(20);
    }
}
