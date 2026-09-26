package pztools.extensions.vehicle.model;

import java.util.Map;

public final class SteeringModelTest {
    public static void main(String[] args) {
        var config=DrivetrainConfig.defaults();
        var model=new SteeringModel(config);
        double first=model.step(1,0,.9,0,100,1d/60), previous=first;
        check(first<0 && first>-.05,"first key response must be immediate and gradual, not full lock");
        double second=model.step(1,0,.9,0,100,1d/60);
        check(Math.abs(second-first)>Math.abs(first),"holding increases turn rate");
        for(int i=0;i<120;i++) previous=model.step(1,0,.9,0,100,1d/60);
        near(previous,-.9,"maximum angle preserved");
        double returned=model.step(0,0,.9,0,100,.1);
        check(returned>-.7,"release returns rapidly");
        double counter=model.step(-1,0,.9,0,100,.1);
        check(counter>returned,"opposite direction returns toward center rapidly");
        for(int hz:new int[]{30,60,120,144,240}) {
            double actual=trajectory(config,hz,1), reverse=trajectory(config,hz,-1);
            near(actual,trajectory(config,60,1),"frame-independent integrated ramp");
            near(actual,reverse,"speed attenuation uses absolute speed");
        }
        var highSpeed=new SteeringModel(config); double highAngle=0;
        for(int i=0;i<54;i++) highAngle=highSpeed.step(1,0,.4,100,100,1d/60);
        near(highAngle,-.4,"default high-speed full lock occurs below one second");
        for(int i=0;i<15;i++) highAngle=highSpeed.step(-1,0,.4,100,100,1d/60);
        check(highAngle>=-1e-9,"high-speed opposite key reaches center within a quarter second");
        model.reset();
        near(model.step(1,.3,.4,0,100,1d/60),new SteeringModel(config).step(1,.3,.4,0,100,1d/60),"reset rebases actual angle");
        for(double invalid:new double[]{0,-1,Double.NaN,1}) check(Double.isNaN(model.step(1,0,.9,0,100,invalid)),"invalid dt rejected");
        check(Double.isNaN(model.step(Double.NaN,0,.9,0,100,1d/60)),"invalid input rejected");
        var fast=new SteeringModel(DrivetrainConfig.parse(Map.of("steering_initial_rate","3.0","steering_full_rate","8.0","steering_ramp_seconds","0.05")));
        check(Math.abs(fast.step(1,0,.9,0,100,1d/60))>Math.abs(first),"rates honor configuration");
        tripleSpeedDefaults(config);
        System.out.println("PASS steering model: immediate/ramped input, one-third full-lock time, unchanged return/countersteer, absolute speed, bounds, reset and frame independence");
    }
    private static void tripleSpeedDefaults(DrivetrainConfig current) {
        var baseline=DrivetrainConfig.parse(Map.of("steering_initial_rate","0.6","steering_full_rate","2.5","steering_ramp_seconds","0.3"));
        near(current.steeringInitialRate,1.8,"new initial rate");
        near(current.steeringFullRate,7.5,"new sustained rate");
        near(current.steeringRampSeconds,.1,"new ramp duration");
        near(current.steeringReturnRate,3,"release rate unchanged");
        near(current.steeringCountersteerRate,4,"countersteer-to-center rate unchanged");
        near(current.steeringHighSpeedRateFactor,.6,"speed attenuation unchanged");
        for(int hz:new int[]{30,60,120,144,240})
            for(double input:new double[]{-1,1})
                for(double cap:new double[]{.15,.4,.9,1.4})
                    for(double speed:new double[]{0,35,-65,100,150}) {
                        double oldTime=fullLockTime(baseline,input,cap,speed,100,hz);
                        double newTime=fullLockTime(current,input,cap,speed,100,hz);
                        // Fixed-frame observation rounds each hit up independently; allow one new-frame interval.
                        check(Math.abs(newTime-oldTime/3)<=1d/hz+1e-12,
                            "full-lock time must be one third across direction/speed/cap/frame rate: "+oldTime+" -> "+newTime+" at "+hz+" Hz");
                        double speedFactor=1+(.6-1)*Math.min(1,Math.abs(speed)/100);
                        double exactOld=.3+(1/speedFactor-.3*(.6+2.5)/2)/2.5;
                        check(oldTime+1e-12>=exactOld && oldTime-exactOld<=1d/hz+1e-12,"baseline full-lock timing");
                        check(newTime+1e-12>=exactOld/3 && newTime-exactOld/3<=1d/hz+1e-12,"new full-lock timing");
                        sameReturnToCenter(baseline,current,input*cap,cap,speed,hz,false);
                        sameReturnToCenter(baseline,current,input*cap,cap,speed,hz,true);
                    }
    }
    private static double fullLockTime(DrivetrainConfig config,double input,double cap,double speed,double maximumSpeed,int hz) {
        var model=new SteeringModel(config);
        for(int frame=1;frame<=hz*2;frame++) {
            double angle=model.step(input,0,cap,speed,maximumSpeed,1d/hz);
            check(Double.isFinite(angle) && Math.abs(angle)<=cap,"full-lock angle cap preserved");
            if(Math.abs(angle+input*cap)<1e-12) return (double)frame/hz;
        }
        throw new AssertionError("full lock not reached within the expected bound");
    }
    private static void sameReturnToCenter(DrivetrainConfig baseline,DrivetrainConfig current,double start,double cap,double speed,int hz,boolean counter) {
        var before=new SteeringModel(baseline); var after=new SteeringModel(current);
        double duration=Math.abs(start)/(cap*(counter?4:3)), time=0, oldAngle=start, newAngle=start;
        double input=counter?Math.signum(start):0;
        while(time<duration-1e-12) {
            // Stop exactly at center: beyond this point opposite-key input intentionally uses the faster new ramp.
            double dt=Math.min(1d/hz,duration-time);
            oldAngle=before.step(input,start,cap,speed,100,dt);
            newAngle=after.step(input,start,cap,speed,100,dt);
            near(newAngle,oldAngle,counter?"countersteer path to center unchanged":"release path to center unchanged");
            time+=dt;
        }
        near(time,duration,"return-to-center duration unchanged");
        near(oldAngle,0,"baseline reaches center");
        near(newAngle,0,"new defaults reach center at the same time");
    }
    private static double trajectory(DrivetrainConfig config,int hz,int speedSign) {
        var model=new SteeringModel(config); double value=0;
        for(double time=0;time<.5-1e-12;) { double dt=Math.min(1d/hz,.5-time); value=model.step(1,0,.7,45*speedSign,100,dt); time+=dt; }
        for(double time=0;time<.25-1e-12;) { double dt=Math.min(1d/hz,.25-time); value=model.step(-1,0,.7,45*speedSign,100,dt); time+=dt; }
        return value;
    }
    private static void near(double value,double expected,String reason) { check(Double.isFinite(value)&&Math.abs(value-expected)<1e-9,reason+": "+value+" vs "+expected); }
    private static void check(boolean value,String reason) { if(!value)throw new AssertionError(reason); }
}
