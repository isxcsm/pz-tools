package zombie.iso.objects;

import zombie.iso.IsoObject;
import zombie.iso.sprite.IsoSprite;
import zombie.radio.devices.DeviceData;
import zombie.radio.devices.WaveSignalDevice;

/** Synthetic. */
public class IsoRadio extends IsoObject implements WaveSignalDevice {
    public final DeviceData device = new DeviceData(this);
    public IsoRadio(IsoSprite sprite) { super(sprite); powered = true; consumption = 0.01f; }
}
