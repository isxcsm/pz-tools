package zombie.characters;
import zombie.vehicles.BaseVehicle;
public final class IsoPlayer extends IsoGameCharacter { public static IsoPlayer[] players=new IsoPlayer[4]; public BaseVehicle vehicle; public boolean local=true,blockMovement; public boolean isBlockMovement() { return blockMovement; } public boolean isLocalPlayer() { return local; } public BaseVehicle getVehicle() { return vehicle; } }
