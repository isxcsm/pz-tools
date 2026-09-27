package pztools.extensions.vehicle.model;

import java.util.Map;

public final class SteeringModelTest {
    private static final int[] FRAME_RATES={30,60,90,120,144,240};
    public static void main(String[] args) {
        var config=DrivetrainConfig.defaults();
        neutralRampTimes(config);
        continuousCountersteering(config);
        counterFloorCrossover();
        rapidLatestIntent(config);
        releaseAndReset(config);
        floatInputDeadZone(config);
        invalidInputsAndBounds(config);
        System.out.println("PASS steering model: continuous latest-intent countersteer, exact rate-floor integration, fast release, float dead-zone boundaries, neutral ramp timing, bounds/resets and 30-240 Hz independence");
    }

    private static void neutralRampTimes(DrivetrainConfig current) {
        var baseline=DrivetrainConfig.parse(Map.of("steering_initial_rate","0.6","steering_full_rate","2.5","steering_ramp_seconds","0.3"));
        near(current.steeringInitialRate,1.8,"initial rate preserved");
        near(current.steeringFullRate,7.5,"sustained rate preserved");
        near(current.steeringRampSeconds,.1,"ramp duration preserved");
        near(current.steeringHighSpeedRateFactor,.6,"speed attenuation preserved");
        var model=new SteeringModel(current);
        double first=model.step(1,0,.9,0,100,1d/60);
        check(first<0 && first>-.05,"neutral first response is immediate and gradual");
        double second=model.step(1,first,.9,0,100,1d/60);
        check(Math.abs(second-first)>Math.abs(first),"neutral held input increases rate");
        var fast=new SteeringModel(DrivetrainConfig.parse(Map.of("steering_initial_rate","3.0","steering_full_rate","8.0","steering_ramp_seconds","0.05")));
        check(Math.abs(fast.step(1,0,.9,0,100,1d/60))>Math.abs(first),"rates honor configuration");
        for(int hz:FRAME_RATES)
            for(double input:new double[]{-1,1})
                for(double cap:new double[]{.15,.4,.9,1.4})
                    for(double speed:new double[]{0,35,-65,100,150}) {
                        double oldTime=fullLockTime(baseline,input,cap,speed,hz);
                        double newTime=fullLockTime(current,input,cap,speed,hz);
                        check(Math.abs(newTime-oldTime/3)<=1d/hz+1e-12,
                            "neutral full-lock time remains one third: "+oldTime+" -> "+newTime+" at "+hz+" Hz");
                        double factor=1+(current.steeringHighSpeedRateFactor-1)*Math.min(1,Math.abs(speed)/100);
                        double exactOld=.3+(1/factor-.3*(.6+2.5)/2)/2.5;
                        check(oldTime+1e-12>=exactOld && oldTime-exactOld<=1d/hz+1e-12,"baseline full-lock timing");
                        check(newTime+1e-12>=exactOld/3 && newTime-exactOld/3<=1d/hz+1e-12,"neutral full-lock timing preserved");
                    }
    }

    private static void continuousCountersteering(DrivetrainConfig config) {
        near(config.steeringReturnRate,8,"default release rate");
        near(config.steeringCountersteerRate,8,"default countersteer rate");
        check(config.steeringCountersteerRate>=config.steeringFullRate,"default floor covers the complete ramp");
        for(int hz:FRAME_RATES)
            for(double sign:new double[]{-1,1})
                for(double cap:new double[]{.15,.4,.9,1.4})
                    for(double speed:new double[]{0,35,-65,100,150}) {
                        var model=new SteeringModel(config);
                        double angle=sign*cap, duration=2/config.steeringCountersteerRate;
                        for(double time=0;time<duration-1e-12;) {
                            double dt=Math.min(1d/hz,duration-time);
                            double before=angle;
                            angle=model.step(sign,angle,cap,speed,100,dt);
                            time+=dt;
                            near(angle,sign*cap*(1-config.steeringCountersteerRate*time),"constant counter rate before and after center");
                            near(Math.abs(angle-before)/(cap*dt),config.steeringCountersteerRate,"no center rate drop");
                        }
                        near(angle,-sign*cap,"opposite lock reached in 250 ms without a center phase");
                        near(advance(new SteeringModel(config),0,sign*cap,cap,speed,1/config.steeringReturnRate,hz),0,
                            "release reaches center in 125 ms");
                        // A center crossing inside the very first frame must retain the same intent rate.
                        double close=new SteeringModel(config).step(sign,sign*cap*.001,cap,speed,100,1d/hz);
                        near(close,sign*cap*(.001-config.steeringCountersteerRate/hz),"near-center reversal does not restart the neutral ramp");
                    }
    }

    private static void counterFloorCrossover() {
        var config=DrivetrainConfig.parse(Map.of("steering_countersteer_rate","4.0"));
        for(int hz:FRAME_RATES)
            for(double speed:new double[]{0,100,-100})
                for(double duration:new double[]{.027,.075,.1,.17,.28}) {
                    double factor=1+(config.steeringHighSpeedRateFactor-1)*Math.min(1,Math.abs(speed)/100);
                    double initial=config.steeringInitialRate*factor, full=config.steeringFullRate*factor;
                    double crossover=(4-initial)*config.steeringRampSeconds/(full-initial);
                    double rampEnd=Math.min(duration,config.steeringRampSeconds);
                    double expected=4*Math.min(duration,crossover);
                    if(duration>crossover)
                        expected+=(4+initial+(full-initial)*rampEnd/config.steeringRampSeconds)*(rampEnd-crossover)/2
                            +full*Math.max(0,duration-config.steeringRampSeconds);
                    double angle=advance(new SteeringModel(config),1,1,1,speed,duration,hz);
                    near(angle,Math.max(-1,1-expected),"counter=4 exact floor/ramp crossover at "+hz+" Hz");
                }
        // The ramp clock must advance even while the actual wheels are still on the old side.
        var slow=DrivetrainConfig.parse(Map.of("steering_initial_rate","0.6","steering_full_rate","2.5",
            "steering_ramp_seconds","0.3","steering_countersteer_rate","0.5"));
        for(int hz:FRAME_RATES) {
            var model=new SteeringModel(slow);
            double before=advance(model,1,1,1,0,.35,hz);
            check(before>0,"test remains before center after the ramp duration");
            double after=model.step(1,before,1,0,100,.01);
            near((before-after)/.01,slow.steeringFullRate,"held time advances before center");
        }
        for(double floor:new double[]{.5,2}) {
            var flat=DrivetrainConfig.parse(Map.of("steering_initial_rate","1.0","steering_full_rate","1.0",
                "steering_countersteer_rate",Double.toString(floor)));
            near(new SteeringModel(flat).step(1,.4,.4,0,100,.01),.4-Math.max(1,floor)*.4*.01,
                "flat ramp has no divide-by-zero boundary");
        }
    }

    private static void rapidLatestIntent(DrivetrainConfig config) {
        double[] reference=trajectory(config,60,1);
        for(int hz:FRAME_RATES)
            for(int speedSign:new int[]{-1,1}) {
                double[] actual=trajectory(config,hz,speedSign);
                for(int i=0;i<actual.length;i++) near(actual[i],reference[i],"rapid latest-input frame/speed-sign independence, segment "+i);
            }
        // Reverse twice before either motion can finish; the latest target wins immediately.
        var model=new SteeringModel(config);
        double left=model.step(1,0,.9,0,100,.02);
        double right=model.step(-1,left,.9,0,100,.005);
        check(right>left && right<0,"opposite intent starts before reaching center");
        double leftAgain=model.step(1,right,.9,0,100,.005);
        check(leftAgain<right,"second reversal immediately follows the latest input");
        near((right-leftAgain)/(.9*.005),config.steeringCountersteerRate,"rapid reversal retains counter floor on either side");
        double released=model.step(0,leftAgain,.9,0,100,.005);
        check(Math.abs(released)<Math.abs(leftAgain),"release immediately replaces the turning target");
    }

    private static void releaseAndReset(DrivetrainConfig config) {
        for(int hz:FRAME_RATES) {
            var model=new SteeringModel(config);
            double angle=model.step(1,.9,.9,0,100,1d/hz);
            angle=advance(model,0,angle,.9,0,1/config.steeringReturnRate,hz);
            near(angle,0,"release centers without overshoot");
            near(model.step(1,angle,.9,0,100,1d/hz),new SteeringModel(config).step(1,0,.9,0,100,1d/hz),
                "release clears counter intent and held ramp before a fresh neutral press");
            model.reset();
            near(model.step(-1,.3,.4,0,100,1d/hz),new SteeringModel(config).step(-1,.3,.4,0,100,1d/hz),
                "explicit reset rebases actual angle and intent");
        }
    }

    private static void floatInputDeadZone(DrivetrainConfig config) {
        double dt=1d/60;
        for(int sign:new int[]{-1,1}) for(float magnitude:new float[]{Math.nextDown(.1f),.1f,Math.nextUp(.1f)}) {
            float input=sign*magnitude;
            double angle=new SteeringModel(config).step(input,0,.9,0,100,dt);
            if(magnitude>.1f) check(angle*sign<0,"the first float above the dead zone still steers");
            else {
                near(angle,0,"float boundary and its inward neighbor remain neutral for either sign");
                double returning=new SteeringModel(config).step(input,.4,.9,0,100,dt);
                near(returning,new SteeringModel(config).step(0,.4,.9,0,100,dt),
                    "float dead-zone input has the same return behavior as released input");
            }
        }
    }

    private static void invalidInputsAndBounds(DrivetrainConfig config) {
        double dt=1d/60;
        double[][] invalid={
            {Double.NaN,0,.9,0,100,dt},{Double.POSITIVE_INFINITY,0,.9,0,100,dt},{1.01,0,.9,0,100,dt},
            {1,Double.NaN,.9,0,100,dt},{1,Double.POSITIVE_INFINITY,.9,0,100,dt},
            {1,0,0,0,100,dt},{1,0,-.1,0,100,dt},{1,0,Math.PI+.01,0,100,dt},{1,0,Double.NaN,0,100,dt},
            {1,0,.9,Double.NaN,100,dt},{1,0,.9,0,0,dt},{1,0,.9,0,Double.POSITIVE_INFINITY,dt},
            {1,0,.9,0,100,0},{1,0,.9,0,100,-1},{1,0,.9,0,100,Double.NaN},{1,0,.9,0,100,config.maxDtSeconds+.001}
        };
        for(double[] args:invalid) {
            var model=new SteeringModel(config);
            model.step(1,.9,.9,0,100,dt);
            check(Double.isNaN(model.step(args[0],args[1],args[2],args[3],args[4],args[5])),"invalid input declines without a game value");
            near(model.step(-1,.3,.4,0,100,dt),new SteeringModel(config).step(-1,.3,.4,0,100,dt),
                "invalid input clears actual angle, held time and counter intent");
        }
        var model=new SteeringModel(config);
        double angle=model.step(0,100,.4,0,100,.01);
        near(angle,.4-config.steeringReturnRate*.4*.01,"initial actual angle is clamped");
        advance(model,1,angle,.9,0,1,60);
        near(model.step(1,-.9,.2,100,100,dt),-.2,"changed maximum angle remains authoritative");
        near(new SteeringModel(config).step(.1,.2,.4,0,100,.01),.2-config.steeringReturnRate*.4*.01,"input dead zone retains return behavior");
    }

    private static double fullLockTime(DrivetrainConfig config,double input,double cap,double speed,int hz) {
        var model=new SteeringModel(config);
        for(int frame=1;frame<=hz*2;frame++) {
            double angle=model.step(input,0,cap,speed,100,1d/hz);
            check(Double.isFinite(angle) && Math.abs(angle)<=cap,"full-lock angle cap preserved");
            if(Math.abs(angle+input*cap)<1e-12) return (double)frame/hz;
        }
        throw new AssertionError("full lock not reached within the expected bound");
    }
    private static double[] trajectory(DrivetrainConfig config,int hz,int speedSign) {
        double[] inputs={1,-1,1,0,-1,1,0,1}, durations={.071,.043,.029,.017,.081,.023,.137,.047};
        double[] result=new double[inputs.length];
        var model=new SteeringModel(config); double angle=0;
        for(int i=0;i<inputs.length;i++) result[i]=angle=advance(model,inputs[i],angle,.7,45*speedSign,durations[i],hz);
        return result;
    }
    private static double advance(SteeringModel model,double input,double angle,double cap,double speed,double duration,int hz) {
        double target=input==0?0:-Math.signum(input)*cap*Math.min(1,Math.abs(input));
        for(double time=0;time<duration-1e-12;) {
            double dt=Math.min(1d/hz,duration-time), before=angle;
            angle=model.step(input,angle,cap,speed,100,dt);
            check(Double.isFinite(angle) && Math.abs(angle)<=cap,"trajectory respects the current angle cap");
            check(Math.abs(target-angle)<=Math.abs(target-before)+1e-12,"each step follows the latest target");
            time+=dt;
        }
        return angle;
    }
    private static void near(double value,double expected,String reason) { check(Double.isFinite(value)&&Math.abs(value-expected)<1e-9,reason+": "+value+" vs "+expected); }
    private static void check(boolean value,String reason) { if(!value)throw new AssertionError(reason); }
}
