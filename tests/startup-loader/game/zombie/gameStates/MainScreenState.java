package zombie.gameStates;

/** Synthetic game entry for the startup loader test. Mirrors the order that matters: the property list, then GameWindow. */
public final class MainScreenState {
    public static void main(String[] args) throws Exception {
        // The game writes every system property to its log here; the control secret must not be among them yet.
        boolean endpointAtListing = System.getProperty("pztools.bridge.control.v1") != null;
        Class.forName("zombie.GameWindow");
        boolean endpointAfter = System.getProperty("pztools.bridge.control.v1") != null;
        System.out.println("STARTUP-FIXTURE\t" + System.getProperty("pztools.bridge.bootstrap.api") + "\t"
            + endpointAtListing + "\t" + endpointAfter);
    }
}
