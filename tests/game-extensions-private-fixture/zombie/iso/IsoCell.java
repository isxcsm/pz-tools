package zombie.iso;
import java.io.*;
public final class IsoCell {
    private final IsoChunkMap chunkMap = new IsoChunkMap();
    private final int marker = 249;
    public void save(DataOutputStream out, boolean full) throws IOException { out.writeInt(marker); chunkMap.Save(); }
    public IsoChunkMap map() { return chunkMap; }
}
