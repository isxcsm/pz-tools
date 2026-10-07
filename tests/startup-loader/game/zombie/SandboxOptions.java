package zombie;

/** Synthetic: the sandbox's generator fuel rate. */
public final class SandboxOptions {
    public static final SandboxOptions instance = new SandboxOptions();
    public final DoubleSandboxOption generatorFuelConsumption = new DoubleSandboxOption(0.1);

    public static final class DoubleSandboxOption {
        private final double value;
        public DoubleSandboxOption(double value) { this.value = value; }
        public double getValue() { return value; }
    }
}
