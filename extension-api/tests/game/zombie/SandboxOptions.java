package zombie;

import java.util.HashMap;

/**
 * Synthetic: the sandbox's generator fuel rate, the day the grid's power goes (-1: as the game has it, never here),
 * whether the grid runs (off unless a test turns it on) and the day the mains' water goes (-1: they never run here);
 * the options by name, which a test adds to as a mod's sandbox-options.txt does.
 */
public final class SandboxOptions {
    public static final SandboxOptions instance = new SandboxOptions();
    public final DoubleSandboxOption generatorFuelConsumption = new DoubleSandboxOption(0.1);
    public int elecShutModifier = -1;
    public int getElecShutModifier() { return elecShutModifier; }
    public boolean powerGrid;
    public boolean doesPowerGridExist() { return powerGrid; }
    public int waterShutModifier = -1;
    public int getWaterShutModifier() { return waterShutModifier; }
    public final HashMap<String, SandboxOption> optionByName = new HashMap<>();
    public SandboxOption getOptionByName(String name) { return optionByName.get(name); }

    public interface SandboxOption { }

    public static final class DoubleSandboxOption implements SandboxOption {
        private double value;
        public DoubleSandboxOption(double value) { this.value = value; }
        public double getValue() { return value; }
        public void setValue(double value) { this.value = value; }
    }

    public static final class BooleanSandboxOption implements SandboxOption {
        private boolean value;
        public BooleanSandboxOption(boolean value) { this.value = value; }
        public boolean getValue() { return value; }
        public void setValue(boolean value) { this.value = value; }
    }
}
