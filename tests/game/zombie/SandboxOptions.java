package zombie;

/** Synthetic: the sandbox's generator fuel rate, and the day the grid's power goes (-1: as the game has it, never here). */
public final class SandboxOptions {
    public static final SandboxOptions instance = new SandboxOptions();
    public final DoubleSandboxOption generatorFuelConsumption = new DoubleSandboxOption(0.1);
    public int elecShutModifier = -1;
    public int getElecShutModifier() { return elecShutModifier; }

    public static final class DoubleSandboxOption {
        private final double value;
        public DoubleSandboxOption(double value) { this.value = value; }
        public double getValue() { return value; }
    }
}
