package pztools.bridge;

import com.sun.tools.attach.VirtualMachine;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** A short-lived helper; no commands or Lua text are evaluated here. */
public final class AttachMain {
    public static void main(String[] args) throws Exception {
        if (args.length != 4) throw new IllegalArgumentException("Expected pid, agent jar, port, token");
        long pid = Long.parseLong(args[0]);
        int port = Integer.parseInt(args[2]);
        if (pid <= 0 || port < 1 || port > 65535 || !args[3].matches("[0-9a-f]{64}"))
            throw new IllegalArgumentException("Invalid connection parameters");
        VirtualMachine vm = VirtualMachine.attach(Long.toString(pid));
        try {
            // Embedded Windows JVM launchers need not preload jli.dll, unlike java.exe.
            // Use the official native-agent attach entry point to load the target's own
            // launcher dependency, without editing PATH or the game installation.
            vm.loadAgentPath(Path.of(args[1]).toAbsolutePath().getParent()
                .resolve("pztools-attach-bootstrap.dll").toString());
            Path payload = Path.of(args[1]).toAbsolutePath();
            vm.loadAgent(payload.getParent().resolve("pztools-save-bootstrap.jar").toString(),
                port + ":" + args[3] + ":" + Base64.getEncoder().encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8)));
        }
        finally { vm.detach(); }
    }
}
