package pztools.extensions.vehicle.model;

public final class SteeringModelTest {
    public static void main(String[] args) {
        wholeUpdatesAreTheGamesOwnStep();
        partialHoldsComposeAndAreOrdered();
        tapLengthDecidesTheAngleNotTheFrameRate();
        speedSlowsSteeringLikeTheGame();
        invalidInputsDecline();
        heldInputFollowsTheGamesConfirmation();
        heldInputDropsWhatTheGameNeverAccepted();
        heldInputReportsDisagreement();
        System.out.println("PASS steering model: exact game step for whole updates, composable partial holds, frame-rate independent taps, game-confirmed held time");
    }

    /** The game's lines, in the game's own float arithmetic. */
    private static float gameHeld(float steering,float input,float multiplier,float factor) { return steering-(input+steering)*.06f*multiplier*factor; }
    private static float gameReleased(float steering,float multiplier) {
        if(Math.abs(steering)<=.04) return 0;
        return steering>0?Math.max(steering-.04f*multiplier,0):Math.min(steering+.04f*multiplier,0);
    }

    private static void wholeUpdatesAreTheGamesOwnStep() {
        for(float multiplier:new float[]{.25f,.5f,1f,2f,4f}) for(float input:new float[]{-1f,1f,.5f}) for(float speed:new float[]{0,40,95,150,-30}) {
            float factor=Math.max(.1f,1-speed/100f), game=.3f; double model=.3;
            for(int update=0;update<40;update++) {
                game=gameHeld(game,input,multiplier,factor);
                model=SteeringModel.step(input,model,multiplier,speed,100,1,true);
                near(model,game,1e-4,"held update equals the game's line");
            }
            for(int update=0;update<40;update++) {
                game=gameReleased(game,multiplier);
                model=SteeringModel.step(0,model,multiplier,speed,100,0,false);
                near(model,game,1e-4,"released update equals the game's line");
            }
        }
        near(SteeringModel.step(0,.04,1,0,100,0,false),0,0,"the game's snap to centre is kept");
        // Input inside the dead zone is a release, whatever the measurement said.
        near(SteeringModel.step(.1f,.5,1,0,100,1,true),SteeringModel.step(0,.5,1,0,100,0,false),0,"dead-zone input releases");
        near(SteeringModel.step(Math.nextUp(.1f),0,1,0,100,1,true),-Math.nextUp(.1f)*.06f,1e-9,"first float above the dead zone steers");
    }

    private static void partialHoldsComposeAndAreOrdered() {
        for(double multiplier:new double[]{.5,1,2}) for(double speed:new double[]{0,60}) {
            double whole=SteeringModel.step(1,.2,multiplier,speed,100,1,true);
            // A press confirmed one update late carries its time over: two updates' worth in one.
            double twice=SteeringModel.step(1,SteeringModel.step(1,.2,multiplier,speed,100,1,true),multiplier,speed,100,1,true);
            near(SteeringModel.step(1,.2,multiplier,speed,100,2,true),twice,1e-12,"carried time equals the updates it stands for");
            // Splitting one held update into parts changes nothing.
            double perUpdate=SteeringModel.APPROACH*multiplier*SteeringModel.speedFactor(speed,100);
            double half=1-Math.sqrt(1-perUpdate);
            double split=.2-(1+.2)*half; split=split-(1+split)*half;
            near(split,whole,1e-12,"two half shares close the same distance as one update");
        }
        // Released before the update ended: steer first, then return for the rest.
        double keep=1-SteeringModel.APPROACH, back=SteeringModel.RETURN;
        double steered=-.5-(1-.5)*(1-Math.pow(keep,.25));
        near(SteeringModel.step(1,-.5,1,0,100,.25,false),steered+back*.75,1e-12,"a key let go mid-update returns for the remainder");
        near(SteeringModel.step(1,0,1,0,100,.25,false),0,0,"a short tap from centre is back at centre by the end of its update");
        // Still down at the end: the return belongs to the time before the press.
        near(SteeringModel.step(1,.5,1,0,100,.25,true),(.5-back*.75)-(1+.5-back*.75)*(1-Math.pow(keep,.25)),1e-12,
            "a key pressed mid-update steers from where the return left off");
        near(SteeringModel.step(1,.01,1,0,100,.5,true),-(1-Math.pow(keep,.5)),1e-12,"return snaps to centre within its share before steering");
    }

    private static void tapLengthDecidesTheAngleNotTheFrameRate() {
        // The same 40 ms tap from rest, measured exactly, at different frame rates and phases:
        // how far the wheels got by the moment the key was let go.
        double reference=Double.NaN;
        for(int hz:new int[]{30,60,90,144,240}) for(double phase:new double[]{0,.3,.7}) {
            double frame=1d/hz, multiplier=60d/hz, start=phase*frame, end=start+.040, angle=0;
            for(int index=0;index<hz;index++) {
                double from=index*frame, to=from+frame;
                double held=Math.max(0,Math.min(to,end)-Math.max(from,start))/frame;
                boolean heldAtEnd=end>=to && start<to;
                if(held>0) angle=SteeringModel.step(1,angle,multiplier,0,100,held,heldAtEnd);
                // The update that contains the release has already begun returning; take that back out.
                if(to>=end) { angle-=SteeringModel.RETURN*multiplier*(1-held); break; }
            }
            if(Double.isNaN(reference)) reference=angle;
            // What remains is the game's own per-update rounding, far below a whole frame's worth.
            near(angle,reference,8e-3,"a measured tap steers the same at "+hz+" Hz, phase "+phase);
        }
        // Counted in whole 60 Hz frames, the same tap lands on two or three frames: a 30 % spread.
        double two=0, three=0;
        for(int i=0;i<2;i++) two=SteeringModel.step(1,two,1,0,100,1,true);
        for(int i=0;i<3;i++) three=SteeringModel.step(1,three,1,0,100,1,true);
        check(Math.abs(three-two)>.05 && Math.abs(reference-two)<Math.abs(three-two) && Math.abs(reference-three)<Math.abs(three-two),
            "exact timing lies between the two whole-frame outcomes");
    }

    private static void speedSlowsSteeringLikeTheGame() {
        near(SteeringModel.speedFactor(0,100),1,0,"standing still: full rate");
        near(SteeringModel.speedFactor(50,100),.5,1e-12,"half speed: half rate");
        near(SteeringModel.speedFactor(100,100),.1f,1e-12,"top speed keeps the game's floor");
        near(SteeringModel.speedFactor(250,100),.1f,1e-12,"beyond top speed keeps the floor");
        near(SteeringModel.speedFactor(-50,100),1.5,1e-12,"the game uses the signed speed");
        check(Math.abs(SteeringModel.step(1,0,1,90,100,1,true))<Math.abs(SteeringModel.step(1,0,1,10,100,1,true)),"fast is slower to steer");
    }

    private static void invalidInputsDecline() {
        double[][] invalid={
            {Double.NaN,0,1,0,100,1},{1.01,0,1,0,100,1},{1,Double.NaN,1,0,100,1},{1,4,1,0,100,1},
            {1,0,0,0,100,1},{1,0,-1,0,100,1},{1,0,Double.NaN,0,100,1},{1,0,Double.POSITIVE_INFINITY,0,100,1},
            {1,0,1,Double.NaN,100,1},{1,0,1,0,0,1},{1,0,1,0,Double.NaN,1},
            {1,0,1,0,100,-.1},{1,0,1,0,100,Double.NaN},{1,0,1,0,100,SteeringModel.MAXIMUM_HELD_FRACTION+.01},
            // The game's own step would overshoot here (fast-forward): such updates are left to the game.
            {1,0,17,0,100,1},{1,0,10,-80,100,1},
        };
        for(double[] a:invalid) check(Double.isNaN(SteeringModel.step(a[0],a[1],a[2],a[3],a[4],a[5],true)),"invalid input declines without a value");
        check(Double.isFinite(SteeringModel.step(1,0,16,0,100,1,true)),"the largest non-overshooting step is accepted");
    }

    private static final long UPDATE=16_000_000L;
    private static void heldInputFollowsTheGamesConfirmation() {
        var held=new HeldInput();
        // Press 6 ms before the update ends: the game has not seen it yet.
        check(held.update(0,0,6_000_000L,UPDATE,false,true),"measurement accepted");
        near(held.fraction,0,0,"nothing is steered before the game accepts the press");
        // Next update the game confirms it; the carried time is spent with this update's.
        check(held.update(1,0,UPDATE,UPDATE,false,true),"confirmed");
        near(held.fraction,1+6d/16,1e-12,"time before the confirmation is not lost");
        check(held.heldAtEnd,"still down");
        check(held.update(1,0,UPDATE,UPDATE,false,true),"held");
        near(held.fraction,1,0,"a key held throughout is exactly one update");
        // Released 4 ms into the update while the game's input still says right.
        check(held.update(1,0,4_000_000L,UPDATE,false,false),"release update");
        near(held.fraction,.25,1e-12,"only the time actually held counts"); check(!held.heldAtEnd,"released by the end");
        // The game's input lags one more update: nothing was held, so it is a release.
        check(held.update(1,0,0,UPDATE,false,false),"stale input");
        near(held.fraction,0,0,"a released key steers nothing, whatever the stale input says");
        // Left key, game input negative.
        check(held.update(-1,UPDATE/2,0,UPDATE,true,false),"left");
        near(held.fraction,.5,1e-12,"left is measured on its own key"); check(held.heldAtEnd,"left still down");
    }

    private static void heldInputDropsWhatTheGameNeverAccepted() {
        var held=new HeldInput();
        // Typing in a text box: the key is down for a long time and the game never reports input.
        for(int update=0;update<50;update++) check(held.update(0,0,UPDATE,UPDATE,false,true),"gated update");
        check(held.update(1,0,UPDATE,UPDATE,false,true),"gate opens");
        check(held.fraction<=1+HeldInput.CONFIRMATION_UPDATES,"time typed into a text box is not replayed as steering: "+held.fraction);
        // Both keys down: the game reports neutral, and neither side may build up credit.
        held.reset();
        for(int update=0;update<10;update++) check(held.update(0,UPDATE,UPDATE,UPDATE,true,true),"both down");
        check(held.update(1,0,UPDATE,UPDATE,false,true),"one remains");
        check(held.fraction<=SteeringModel.MAXIMUM_HELD_FRACTION,"credit is bounded");
        // A tap the game never saw at all is dropped after the confirmation window.
        held.reset();
        check(held.update(0,0,5_000_000L,UPDATE,false,false),"unseen tap");
        for(int update=0;update<HeldInput.CONFIRMATION_UPDATES;update++) check(held.update(0,0,0,UPDATE,false,false),"waiting");
        check(held.update(1,0,UPDATE,UPDATE,false,true),"later press");
        near(held.fraction,1,0,"an old unseen tap does not add to a later press");
    }

    private static void heldInputReportsDisagreement() {
        var held=new HeldInput();
        // The game keeps steering right although the bound key was never seen down: wrong keys are being watched.
        boolean trusted=true;
        for(int update=0;update<HeldInput.MISMATCH_UPDATES;update++) trusted=held.update(1,0,0,UPDATE,false,false);
        check(!trusted,"persistent disagreement hands steering back to the game's input");
        check(!held.update(1,0,0,0,false,false),"an empty span cannot be measured");
        check(!held.update(1,0,-1,UPDATE,false,false),"negative time is rejected");
        check(!held.update(Double.NaN,0,0,UPDATE,false,false),"invalid input is rejected");
    }

    private static void near(double value,double expected,double tolerance,String reason) {
        check(Double.isFinite(value)&&Math.abs(value-expected)<=tolerance,reason+": "+value+" vs "+expected);
    }
    private static void check(boolean value,String reason) { if(!value)throw new AssertionError(reason); }
}
