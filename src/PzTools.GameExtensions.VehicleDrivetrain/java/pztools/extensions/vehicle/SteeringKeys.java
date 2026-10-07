package pztools.extensions.vehicle;

import java.util.Arrays;
import pztools.extensions.runtime.input.*;

/**
 * Keeps one key timeline matched to the game's current Left/Right bindings. Game thread only,
 * except {@link #stop}. Every failure here means "time the keys the ordinary way", never an error:
 * steering then uses the game's own per-frame input.
 */
final class SteeringKeys {
    /** Tests replace the platform; production uses Windows. */
    interface Platform {
        /** Virtual key for a game key code, 0 when it is not a single keyboard key. */
        int virtualKey(int gameKey) throws Throwable;
        /** A source for one timeline, released by that timeline when it stops. */
        KeyStateSource source() throws Throwable;
    }
    /** Holds nothing: the native binding is shared, and each source closes its own timer when its timeline stops. */
    private static final Platform WINDOWS=new Platform() {
        @Override public int virtualKey(int gameKey) throws Throwable { return WindowsKeys.virtualKeyForGameKey(gameKey); }
        @Override public KeyStateSource source() throws Throwable { return WindowsKeys.open(); }
    };
    private final VehicleAccess access;
    private final Platform platform;
    private final int[] bindings=new int[4], applied={-1,-1,-1,-1};
    private int[] side=new int[0];
    private volatile KeyTimeline timeline;
    private volatile boolean stopped;
    private boolean platformFailed;
    KeyTimeline.Reading reading;
    /** Changes whenever the timeline is replaced: totals from different timelines must not be compared. */
    int generation;
    String state="not-started";

    SteeringKeys(VehicleAccess access,Platform injected) { this.access=access; platform=injected!=null?injected:WINDOWS; }

    /**
     * The measuring thread polls about once a millisecond. Once nothing has asked for a reading for
     * this long (out of the vehicle, in a menu, paused), it is stopped; the next reading starts a new
     * one, and its first update is steered the ordinary way, as after any gap.
     */
    private static final long IDLE_NANOS=2_000_000_000L;
    private long lastRead;

    /** Game thread, every frame: stops a timeline nobody has read for a while. */
    void retireIfIdle(long now) {
        if(timeline!=null && now-lastRead>IDLE_NANOS) retire("idle");
    }

    /** True when {@link #reading} now holds current totals for the bound keys. */
    boolean read() {
        lastRead=System.nanoTime();
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
        KeyStateSource source=platform.source();
        try { timeline=KeyTimeline.start(source,Arrays.copyOf(keys,count)); }
        catch(Throwable failure) { try { source.release(); } catch(Throwable ignored) { } throw failure; }
        if(stopped) stop();
        return true;
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
