package se.krka.kahlua.vm;
public class Coroutine {
    public LuaCallFrame[] frames = new LuaCallFrame[8];
    public int top;
    public int getCallframeTop() { return top; }
    public LuaCallFrame[] getCallframeStack() { return frames; }
}