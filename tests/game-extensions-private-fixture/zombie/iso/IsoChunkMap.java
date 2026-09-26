package zombie.iso;
import java.io.*;
public final class IsoChunkMap {
    private IsoChunk chunk = new IsoChunk();
    public void Save() throws IOException { chunk.Save(true); }
    public void setChunk(IsoChunk next) { chunk = next; }
}
