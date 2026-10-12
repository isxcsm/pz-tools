package zombie.radio.devices;

/** Synthetic: like the game's, a device on mains power has it when its square has. */
public class DeviceData {
    protected WaveSignalDevice parent;
    protected boolean isBatteryPowered;
    public DeviceData(WaveSignalDevice parent) { this.parent = parent; }
    public WaveSignalDevice getParent() { return parent; }
    public boolean getIsBatteryPowered() { return isBatteryPowered; }
    public boolean canBePoweredHere() {
        if (isBatteryPowered) return true;
        return parent != null && parent.getSquare() != null && parent.getSquare().haveElectricity();
    }
}
