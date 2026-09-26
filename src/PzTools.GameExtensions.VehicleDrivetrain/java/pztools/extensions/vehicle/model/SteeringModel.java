package pztools.extensions.vehicle.model;

/** Keyboard-only angular-rate model. No game dependencies; rates are fractions of the current maximum angle per second. */
public final class SteeringModel {
    private final DrivetrainConfig config;
    private boolean initialized;
    private double angle,held;
    private int direction;
    public SteeringModel(DrivetrainConfig config) { this.config=config; }
    public void reset() { initialized=false; angle=held=0; direction=0; }
    /** NaN means decline without a game write. Input sign follows the game's keyboard convention. */
    public double step(double input,double actualAngle,double maximumAngle,double speedKph,double maximumSpeedKph,double dtSeconds) {
        if(!Double.isFinite(input) || Math.abs(input)>1.0001 || !Double.isFinite(actualAngle)
                || !Double.isFinite(maximumAngle) || maximumAngle<=0 || maximumAngle>Math.PI
                || !Double.isFinite(speedKph) || !Double.isFinite(maximumSpeedKph) || maximumSpeedKph<=0
                || !Double.isFinite(dtSeconds) || dtSeconds<=0 || dtSeconds>config.maxDtSeconds) {
            reset(); return Double.NaN;
        }
        if(!initialized) { angle=clamp(actualAngle,-maximumAngle,maximumAngle); initialized=true; }
        angle=clamp(angle,-maximumAngle,maximumAngle);
        int next=Math.abs(input)<=0.1?0:input>0?-1:1;
        if(next!=direction) held=0;
        direction=next;
        if(next==0) {
            angle=approach(angle,0,config.steeringReturnRate*maximumAngle*dtSeconds);
            return angle;
        }
        double remaining=dtSeconds;
        if(angle*next<0) {
            double timeToCenter=Math.abs(angle)/(config.steeringCountersteerRate*maximumAngle);
            if(remaining<=timeToCenter) {
                angle=approach(angle,0,config.steeringCountersteerRate*maximumAngle*remaining);
                return angle;
            }
            remaining-=timeToCenter; angle=0;
        }
        double end=held+remaining;
        double speedFraction=clamp(Math.abs(speedKph)/maximumSpeedKph,0,1);
        double speedFactor=1+(config.steeringHighSpeedRateFactor-1)*speedFraction;
        double travel=(integratedRate(end)-integratedRate(held))*maximumAngle*speedFactor;
        held=Math.min(end,config.steeringRampSeconds);
        angle=approach(angle,next*maximumAngle*Math.min(1,Math.abs(input)),travel);
        return angle;
    }
    private double integratedRate(double seconds) {
        double ramp=Math.min(seconds,config.steeringRampSeconds);
        return config.steeringInitialRate*ramp
            +(config.steeringFullRate-config.steeringInitialRate)*ramp*ramp/(2*config.steeringRampSeconds)
            +Math.max(0,seconds-config.steeringRampSeconds)*config.steeringFullRate;
    }
    private static double approach(double current,double target,double distance) {
        return current<target?Math.min(target,current+distance):Math.max(target,current-distance);
    }
    private static double clamp(double value,double low,double high) { return Math.max(low,Math.min(high,value)); }
}
