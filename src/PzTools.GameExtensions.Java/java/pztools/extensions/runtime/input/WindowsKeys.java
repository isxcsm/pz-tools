package pztools.extensions.runtime.input;

import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.util.concurrent.locks.LockSupport;

/**
 * Windows key state through the JDK's foreign-function interface: no native library of our own,
 * no hook, nothing installed into the system. It only asks whether a given key is down.
 * One instance serves one timeline.
 */
public final class WindowsKeys implements KeyStateSource {
    private static final int MAPVK_VSC_TO_VK_EX = 3;
    private static final int HIGH_RESOLUTION = 0x2, TIMER_ACCESS = 0x1F0003;
    private final MethodHandle keyState, foregroundWindow, windowProcess, mapVirtualKey;
    private final MethodHandle setTimer, waitFor, closeHandle;
    private final MemorySegment processSlot, dueSlot;
    private final int process;
    private MemorySegment timer;

    private WindowsKeys() throws Throwable {
        if (!System.getProperty("os.name", "").startsWith("Windows")) throw new UnsupportedOperationException("not-windows");
        Linker linker = Linker.nativeLinker();
        SymbolLookup user = SymbolLookup.libraryLookup("user32", Arena.global());
        SymbolLookup kernel = SymbolLookup.libraryLookup("kernel32", Arena.global());
        keyState = linker.downcallHandle(user.find("GetAsyncKeyState").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_SHORT, ValueLayout.JAVA_INT));
        foregroundWindow = linker.downcallHandle(user.find("GetForegroundWindow").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.ADDRESS));
        windowProcess = linker.downcallHandle(user.find("GetWindowThreadProcessId").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.ADDRESS));
        mapVirtualKey = linker.downcallHandle(user.find("MapVirtualKeyW").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT));
        MethodHandle createTimer = linker.downcallHandle(kernel.find("CreateWaitableTimerExW").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT));
        setTimer = linker.downcallHandle(kernel.find("SetWaitableTimer").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT,
                ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        waitFor = linker.downcallHandle(kernel.find("WaitForSingleObject").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        closeHandle = linker.downcallHandle(kernel.find("CloseHandle").orElseThrow(),
            FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS));
        Arena arena = Arena.ofAuto();
        processSlot = arena.allocate(ValueLayout.JAVA_INT);
        dueSlot = arena.allocate(ValueLayout.JAVA_LONG);
        process = (int)ProcessHandle.current().pid();
        // A private high-resolution timer: precise short waits without raising the system-wide
        // timer rate. Older Windows has none; the portable wait is then used and may be coarse.
        MemorySegment created = (MemorySegment)createTimer.invokeExact(MemorySegment.NULL, MemorySegment.NULL, HIGH_RESOLUTION, TIMER_ACCESS);
        timer = created.address() == 0 ? null : created;
    }

    /** Throws when the platform or the JVM's native-access policy does not allow it; callers fall back. */
    public static WindowsKeys open() throws Throwable { return new WindowsKeys(); }

    /** Whether short waits are precise here; without it a timeline reports its intervals as unreliable. */
    public boolean preciseWait() { return timer != null; }

    @Override public boolean down(int virtualKey) throws Throwable {
        return ((short)keyState.invokeExact(virtualKey) & 0x8000) != 0;
    }

    /** Called from one thread only: the process-id slot is reused. */
    @Override public boolean focused() throws Throwable {
        MemorySegment window = (MemorySegment)foregroundWindow.invokeExact();
        if (window.address() == 0) return false;
        processSlot.set(ValueLayout.JAVA_INT, 0, 0);
        int thread = (int)windowProcess.invokeExact(window, processSlot);
        return thread != 0 && processSlot.get(ValueLayout.JAVA_INT, 0) == process;
    }

    @Override public void pause(long nanos) throws Throwable {
        MemorySegment current = timer;
        if (current != null) {
            dueSlot.set(ValueLayout.JAVA_LONG, 0, -Math.max(1, nanos / 100)); // Relative, in 100 ns units.
            int armed = (int)setTimer.invokeExact(current, dueSlot, 0, MemorySegment.NULL, MemorySegment.NULL, 0);
            if (armed != 0) {
                int result = (int)waitFor.invokeExact(current, 100);
                if (result == 0) return;
            }
        }
        LockSupport.parkNanos(this, nanos);
    }

    @Override public void release() throws Throwable {
        MemorySegment current = timer;
        timer = null;
        if (current != null) { int closed = (int)closeHandle.invokeExact(current); }
    }

    /**
     * Virtual key for a game key code. The game keeps the LWJGL 2 numbering, which is the keyboard
     * scan code with 0x80 added for the extended keys (arrows, right Ctrl, keypad Enter, ...), so a
     * binding names a physical key and follows the active keyboard layout like the game does.
     * Returns 0 for anything that is not one keyboard key: unbound, a mouse button, out of range.
     */
    public int virtualKeyForGameKey(int gameKey) throws Throwable {
        if (gameKey <= 0 || gameKey > 0xFF) return 0;
        int scanCode = gameKey < 0x80 ? gameKey : 0xE000 | (gameKey & 0x7F);
        int virtualKey = (int)mapVirtualKey.invokeExact(scanCode, MAPVK_VSC_TO_VK_EX);
        return virtualKey > 0 && virtualKey < 0xFF ? virtualKey : 0;
    }
}
