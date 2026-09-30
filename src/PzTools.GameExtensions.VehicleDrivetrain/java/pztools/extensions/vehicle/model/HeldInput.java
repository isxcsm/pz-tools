package pztools.extensions.vehicle.model;

/**
 * Joins two views of the steering keys: how long each was really held (measured off the game
 * thread) and what the game accepted as input (decided on the game thread, one update late).
 *
 * <p>The game stays the authority on whether a key counts at all: text entry, menus, aiming and
 * its other gates never reach this class as input. Measured time is only spent once the game has
 * confirmed that direction, so nothing is steered that the game itself would not have steered.
 * No game dependencies; one instance per vehicle controller, game thread only.
 */
public final class HeldInput {
    /** A press waits this many updates for the game's confirmation before its time is dropped. */
    static final int CONFIRMATION_UPDATES=3;
    /** The game insisting on a direction whose key was never seen down means the two views disagree. */
    static final int MISMATCH_UPDATES=6;
    private final double[] pending=new double[2];
    private final int[] age=new int[2];
    private int mismatch;
    /** Set by {@link #update}: share of this update the confirmed key was down, and whether it still is. */
    public double fraction;
    public boolean heldAtEnd;

    public void reset() { pending[0]=pending[1]=0; age[0]=age[1]=0; mismatch=0; fraction=0; heldAtEnd=false; }

    /**
     * @param input the game's steering input for this update: positive right, negative left
     * @param leftNanos,rightNanos measured time each key was down since the previous update
     * @param updateNanos measured length of that span
     * @param leftDown,rightDown whether each key is down now
     * @return false when the measurement cannot be trusted; the caller then uses the game's input as is
     */
    public boolean update(double input,long leftNanos,long rightNanos,long updateNanos,boolean leftDown,boolean rightDown) {
        fraction=0; heldAtEnd=false;
        if(updateNanos<=0 || leftNanos<0 || rightNanos<0 || !Double.isFinite(input)) { reset(); return false; }
        accumulate(0,leftNanos,updateNanos); accumulate(1,rightNanos,updateNanos);
        int direction=input>SteeringModel.INPUT_DEAD_ZONE?1:input<-SteeringModel.INPUT_DEAD_ZONE?0:-1;
        if(direction<0) {
            mismatch=0;
            for(int side=0;side<2;side++) if(pending[side]>0 && ++age[side]>CONFIRMATION_UPDATES) { pending[side]=0; age[side]=0; }
            return true;
        }
        boolean down=direction==0?leftDown:rightDown;
        double measured=pending[direction];
        pending[0]=pending[1]=0; age[0]=age[1]=0;
        if(measured<=0 && !down) {
            // The key was let go before this update; the game's input has simply not caught up yet.
            if(++mismatch>=MISMATCH_UPDATES) { reset(); return false; }
            return true;
        }
        mismatch=0;
        fraction=Math.min(SteeringModel.MAXIMUM_HELD_FRACTION,measured);
        heldAtEnd=down;
        return true;
    }

    private void accumulate(int side,long heldNanos,long updateNanos) {
        if(heldNanos<=0) return;
        pending[side]=Math.min(SteeringModel.MAXIMUM_HELD_FRACTION,pending[side]+(double)heldNanos/updateNanos);
    }
}
