package pztools.extensions.vehicle.model;

/** Keyboard-only angular-rate model. No game dependencies; rates are fractions of the current maximum angle per second. */
public final class SteeringModel {
    private final DrivetrainConfig config;
    private boolean initialized,countersteering;
    private double angle,held;
    private int direction;
    public SteeringModel(DrivetrainConfig config) { this.config=config; }
    public void reset() { initialized=countersteering=false; angle=held=0; direction=0; }
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
        if(next!=direction) {
            held=0;
            // Countersteering belongs to the latest held intent, not to one side of center.
            // A rapid second reversal must react immediately even before the first crossed zero.
            countersteering=next!=0 && (direction!=0 || angle*next<0);
        }
        direction=next;
        if(next==0) {
            held=0; countersteering=false;
            angle=approach(angle,0,config.steeringReturnRate*maximumAngle*dtSeconds);
            return angle;
        }
        double end=held+dtSeconds;
        double speedFraction=clamp(Math.abs(speedKph)/maximumSpeedKph,0,1);
        double speedFactor=1+(config.steeringHighSpeedRateFactor-1)*speedFraction;
        double floor=countersteering?config.steeringCountersteerRate:0;
        double travel=(integratedRate(end,speedFactor,floor)-integratedRate(held,speedFactor,floor))*maximumAngle;
        held=Math.min(end,config.steeringRampSeconds);
        angle=approach(angle,next*maximumAngle*Math.min(1,Math.abs(input)),travel);
        return angle;
    }
    /** Exact integral of max(speed-adjusted ramp, countersteer floor), including its crossover. */
    private double integratedRate(double seconds,double speedFactor,double floor) {
        double initial=config.steeringInitialRate*speedFactor, full=config.steeringFullRate*speedFactor;
        if(floor>=full) return floor*seconds;
        double ramp=Math.min(seconds,config.steeringRampSeconds);
        double slope=(full-initial)/config.steeringRampSeconds;
        double travel=initial*ramp+slope*ramp*ramp/2+Math.max(0,seconds-config.steeringRampSeconds)*full;
        if(floor>initial) {
            double floorTime=Math.min(seconds,(floor-initial)/slope);
            travel+=(floor-initial)*floorTime-slope*floorTime*floorTime/2;
        }
        return travel;
    }
    private static double approach(double current,double target,double distance) {
        return current<target?Math.min(target,current+distance):Math.max(target,current-distance);
    }
    private static double clamp(double value,double low,double high) { return Math.max(low,Math.min(high,value)); }
}
