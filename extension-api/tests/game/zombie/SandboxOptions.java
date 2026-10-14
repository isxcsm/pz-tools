package zombie;

/**
 * Synthetic: the sandbox's generator fuel rate, the day the grid's power goes (-1: as the game has it, never here),
 * whether the grid runs (off unless a test turns it on) and the day the mains' water goes (-1: they never run here).
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

    public static final class DoubleSandboxOption {
        private final double value;
        public DoubleSandboxOption(double value) { this.value = value; }
        public double getValue() { return value; }
    }
}
