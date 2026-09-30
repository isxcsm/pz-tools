package zombie.iso;
/** Synthetic light: the members the area light reads and writes, nothing else. */
public class IsoLightSource {
    public int x,y,z,radius,life;
    public float r,g,b;
    public IsoLightSource(int x,int y,int z,float r,float g,float b,int radius) {
        this.x=x; this.y=y; this.z=z; this.r=r; this.g=g; this.b=b; this.radius=radius;
    }
}