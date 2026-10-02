package zombie.iso;
import java.util.ArrayList;
public final class IsoCell {
    public final ArrayList<IsoLightSource> lampposts=new ArrayList<>();
    public int added,removed;
    public boolean rejectLights;
    public void addLamppost(IsoLightSource light) {
        if(rejectLights) throw new IllegalStateException("synthetic lighting failure");
        if(light==null || lampposts.contains(light)) return;
        lampposts.add(light); added++;
    }
    // As in the game: removal only marks the light; the lighting pass drops it later.
    public void removeLamppost(IsoLightSource light) { light.life=0; removed++; }
    public int litCount() { int count=0; for(IsoLightSource light:lampposts) if(light.life!=0) count++; return count; }
    public IsoLightSource lit() { for(IsoLightSource light:lampposts) if(light.life!=0) return light; return null; }
}