package pztools.extensions.runtime.input;

import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;

/** A scripted key source with its own clock: no real keyboard, timer or native call is involved. */
public final class KeyTimelineTest {
    public static void main(String[] args) throws Exception {
        heldTimeIsMeasuredPerKey();
        unfocusedKeysAreNotInput();
        starvedIntervalsAreReported();
        failureStopsCleanly();
        closeEndsTheThread();
        rejectsInvalidArguments();
        System.out.println("PASS key timeline: per-key held time, midpoint transitions, focus, starvation and failure reporting, clean stop");
    }

    /** One permit is one poll: the test sets the state, advances the clock and waits for the poll to finish. */
    public static final class ScriptedKeys implements KeyStateSource {
        private final Semaphore go=new Semaphore(0), done=new Semaphore(0);
        private volatile long now;
        public volatile boolean focused=true, fail;
        public final boolean[] down=new boolean[256];
        public volatile boolean released;
        @Override public boolean down(int key) { if(fail) throw new IllegalStateException("scripted"); return down[key]; }
        @Override public boolean focused() { return focused; }
        @Override public long nanoTime() { return now; }
        @Override public void pause(long nanos) throws InterruptedException { done.release(); go.acquire(); }
        @Override public void release() { released=true; done.release(1000); }
        public void started() throws InterruptedException { await(); }
        public void poll(double milliseconds) throws InterruptedException {
            now+=(long)(milliseconds*1_000_000); go.release(); await();
        }
        public void finish() { go.release(1000); }
        private void await() throws InterruptedException {
            if(!done.tryAcquire(5,TimeUnit.SECONDS)) throw new AssertionError("timeline thread did not poll");
        }
    }

    private static void heldTimeIsMeasuredPerKey() throws Exception {
        var keys=new ScriptedKeys();
        try(var timeline=KeyTimeline.start(keys,new int[]{37,39})) {
            keys.started();
            var reading=new KeyTimeline.Reading(2);
            keys.poll(1); keys.poll(1);
            check(timeline.read(reading),"readable while idle");
            equal(reading.clock,2_000_000,"clock advances with every poll"); equal(reading.held[0],0,"nothing held"); equal(reading.downMask,0,"nothing down");
            keys.down[37]=true; keys.poll(1);              // Pressed somewhere inside this millisecond.
            keys.poll(1); keys.poll(1);
            keys.down[37]=false; keys.down[39]=true; keys.poll(1);
            check(timeline.read(reading),"readable while held");
            equal(reading.held[0],3_000_000,"a press and a release each count half their interval");
            equal(reading.held[1],500_000,"the other key is measured on its own");
            equal(reading.downMask,2,"mask shows what is down now");
            equal(reading.unreliable,0,"ordinary intervals are reliable");
            keys.poll(2); check(timeline.read(reading),"readable");
            equal(reading.held[1],2_500_000,"a held key gains exactly the elapsed time");
            equal(reading.clock,8_000_000,"held time never exceeds the observed time");
            check(timeline.running() && timeline.failure()==null,"still measuring");
        } finally { keys.finish(); }
    }

    private static void unfocusedKeysAreNotInput() throws Exception {
        var keys=new ScriptedKeys();
        try(var timeline=KeyTimeline.start(keys,new int[]{37})) {
            keys.started();
            var reading=new KeyTimeline.Reading(1);
            keys.down[37]=true; keys.focused=false;
            keys.poll(1); keys.poll(1);
            check(timeline.read(reading),"readable"); equal(reading.held[0],0,"a key held for another window is not counted");
            keys.focused=true; keys.poll(1); keys.poll(1);
            check(timeline.read(reading),"readable"); equal(reading.held[0],1_500_000,"regaining focus counts as a press");
        } finally { keys.finish(); }
    }

    private static void starvedIntervalsAreReported() throws Exception {
        var keys=new ScriptedKeys();
        try(var timeline=KeyTimeline.start(keys,new int[]{37},500_000,5_000_000)) {
            keys.started();
            var reading=new KeyTimeline.Reading(1);
            keys.down[37]=true; keys.poll(1); keys.poll(5); keys.poll(40);
            check(timeline.read(reading),"readable");
            equal(reading.unreliable,40_000_000,"only an interval beyond the tolerance is flagged");
            equal(reading.clock,46_000_000,"flagged time is still part of the clock");
        } finally { keys.finish(); }
    }

    private static void failureStopsCleanly() throws Exception {
        var keys=new ScriptedKeys();
        var timeline=KeyTimeline.start(keys,new int[]{37});
        try {
            keys.started();
            var reading=new KeyTimeline.Reading(1);
            keys.poll(1); check(timeline.read(reading),"readable before the failure");
            keys.fail=true; keys.go.release();
            for(int i=0;i<500 && timeline.failure()==null;i++) Thread.sleep(10);
            check(timeline.failure()!=null && timeline.failure().contains("scripted"),"the reason is kept: "+timeline.failure());
            check(!timeline.read(reading),"a stopped timeline is not read as if it were measuring");
            check(!timeline.running(),"not running");
            for(int i=0;i<500 && !keys.released;i++) Thread.sleep(10);
            check(keys.released,"the source is released when the thread ends");
        } finally { keys.finish(); timeline.close(); }
    }

    private static void closeEndsTheThread() throws Exception {
        var keys=new ScriptedKeys();
        var timeline=KeyTimeline.start(keys,new int[]{37});
        keys.started();
        timeline.stop(); keys.finish();
        for(int i=0;i<500 && !keys.released;i++) Thread.sleep(10);
        check(keys.released,"stop ends the measuring thread and releases the source");
        check(!timeline.read(new KeyTimeline.Reading(1)),"a closed timeline cannot be read");
        timeline.close();
    }

    private static void rejectsInvalidArguments() {
        var keys=new ScriptedKeys();
        for(Runnable invalid:new Runnable[]{
                ()->KeyTimeline.start(keys,new int[0]), ()->KeyTimeline.start(keys,new int[KeyTimeline.MAXIMUM_KEYS+1]),
                ()->KeyTimeline.start(keys,new int[]{1},10,5_000_000), ()->KeyTimeline.start(keys,new int[]{1},1_000_000,500_000),
                ()->KeyTimeline.start(null,new int[]{1})}) {
            boolean rejected=false;
            try { invalid.run(); } catch(IllegalArgumentException | NullPointerException expected) { rejected=true; }
            check(rejected,"invalid arguments are rejected before a thread starts");
        }
    }

    private static void equal(long actual,long expected,String message) { if(actual!=expected) throw new AssertionError(message+": "+actual+" != "+expected); }
    private static void check(boolean condition,String message) { if(!condition) throw new AssertionError(message); }
}
