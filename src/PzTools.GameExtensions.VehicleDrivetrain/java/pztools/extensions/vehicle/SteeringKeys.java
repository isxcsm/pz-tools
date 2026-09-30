package pztools.extensions.vehicle;

import java.util.Arrays;
import pztools.extensions.runtime.input.*;

/**
 * Keeps one key timeline matched to the game's current Left/Right bindings. Game thread only,
 * except {@link #stop}. Every failure here means "time the keys the ordinary way", never an error:
 * steering then uses the game's own per-frame input.
 */
final class SteeringKeys {
    /** Tests replace the platform source; production opens the Windows one on first use. */
    interface Platform {
        /** Virtual key for a game key code, 0 when it is not a single keyboard key. */
        int virtualKey(int gameKey) throws Throwable;
        KeyStateSource source();
    }
    private final VehicleAccess access;
    private final Platform injected;
    private Platform platform;
    private final int[] bindings=new int[4], applied={-1,-1,-1,-1};
    private int[] side=new int[0];
    private volatile KeyTimeline timeline;
    private volatile boolean stopped;
    private boolean platformFailed;
    KeyTimeline.Reading reading;
    /** Changes whenever the timeline is replaced: totals from different timelines must not be compared. */
    int generation;
    String state="not-started";

    SteeringKeys(VehicleAccess access,Platform injected) { this.access=access; this.injected=injected; }

    /** True when {@link #reading} now holds current totals for the bound keys. */
    boolean read() {
        try {
            if(stopped || platformFailed) return false;
            if(!access.steeringKeys(bindings)) { retire("bindings-unavailable"); return false; }
            if(!Arrays.equals(bindings,applied) && !rebind()) return false;
            KeyTimeline current=timeline;
            if(current==null) return false;
            if(!current.read(reading)) {
                if(current.failure()!=null) { platformFailed=true; retire("timeline-failed:"+current.failure()); }
                return false;
            }
            state="measuring";
            return true;
        } catch(Throwable failure) {
            platformFailed=true; retire("unavailable:"+failure.getClass().getSimpleName());
            return false;
        }
    }

    private boolean rebind() throws Throwable {
        retire("rebinding");
        System.arraycopy(bindings,0,applied,0,4);
        if(platform==null) platform=injected!=null?injected:windows();
        int[] keys=new int[4], sides=new int[4]; int count=0; boolean left=false,right=false;
        for(int i=0;i<4;i++) {
            if(bindings[i]==0) continue;
            int virtualKey=platform.virtualKey(bindings[i]);
            // A mouse button or an unknown key cannot be timed; partial timing would steer unevenly.
            if(virtualKey==0) { state="binding-not-a-key"; return false; }
            keys[count]=virtualKey; sides[count++]=i/2;
            if(i<2) left=true; else right=true;
        }
        if(!left || !right) { state="binding-missing"; return false; }
        side=Arrays.copyOf(sides,count);
        reading=new KeyTimeline.Reading(count);
        generation++;
        timeline=KeyTimeline.start(platform.source(),Arrays.copyOf(keys,count));
        if(stopped) stop();
        return true;
    }

    private static Platform windows() throws Throwable {
        WindowsKeys keys=WindowsKeys.open();
        return new Platform() {
            @Override public int virtualKey(int gameKey) throws Throwable { return keys.virtualKeyForGameKey(gameKey); }
            // Each timeline needs its own source: a source's timer ends with the timeline that used it.
            @Override public KeyStateSource source() {
                try { return WindowsKeys.open(); }
                catch(Throwable failure) { throw new IllegalStateException(failure); }
            }
        };
    }

    /** Longest time any key bound to that side (0 left, 1 right) was down since {@code previous}. */
    long held(long[] previous,int wanted) {
        long longest=0;
        for(int i=0;i<side.length;i++) if(side[i]==wanted) longest=Math.max(longest,reading.held[i]-previous[i]);
        return longest;
    }
    boolean down(int wanted) {
        for(int i=0;i<side.length;i++) if(side[i]==wanted && (reading.downMask&1<<i)!=0) return true;
        return false;
    }
    int keyCount() { return side.length; }

    private void retire(String reason) {
        KeyTimeline current=timeline;
        timeline=null;
        if(current!=null) current.stop();
        Arrays.fill(applied,-1);
        state=reason;
    }
    /** Game thread: forget everything, so the next use starts a fresh timeline. */
    void clear() { retire("not-started"); platformFailed=false; }
    /** Any thread, never blocks: the measuring thread ends at its next poll. */
    void stop() {
        stopped=true;
        KeyTimeline current=timeline;
        if(current!=null) current.stop();
    }
}
