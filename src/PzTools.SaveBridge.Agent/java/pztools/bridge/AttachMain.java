package pztools.bridge;

import com.sun.tools.attach.VirtualMachine;
import java.io.*;
import java.net.*;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.Base64;

/** Short-lived helper. Reuses one authenticated bootstrap; never re-loads on dispatch failure. */
public final class AttachMain {
    private static final String CONTROL_PROPERTY = "pztools.bridge.control.v1";
    public static void main(String[] args) throws Exception {
        if (args.length != 4) throw new IllegalArgumentException("Expected pid, agent jar, port, token");
        long pid = Long.parseLong(args[0]);
        int port = Integer.parseInt(args[2]);
        if (pid <= 0 || port < 1 || port > 65535 || !args[3].matches("[0-9a-f]{64}"))
            throw new IllegalArgumentException("Invalid connection parameters");
        Path payload = Path.of(args[1]).toAbsolutePath().normalize();
        String encoded = Base64.getEncoder().encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8));
        // One small per-user lock serializes cold discovery/initialization across worker processes.
        // OS file locks are released when a helper is killed. Do not unlink the shared lock file.
        Path directory = Path.of(System.getProperty("user.home"), ".pztools-bridge");
        Files.createDirectories(directory);
        if (Files.isSymbolicLink(directory)) throw new IOException("Linked bridge lock directory is not supported");
        try (var lockFile = FileChannel.open(directory.resolve("bootstrap.lock"),
                StandardOpenOption.CREATE, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
             var lock = lockFile.lock()) {
            VirtualMachine vm = VirtualMachine.attach(Long.toString(pid));
            String endpoint;
            try {
                endpoint = vm.getSystemProperties().getProperty(CONTROL_PROPERTY);
                if (endpoint == null) {
                    // Embedded Windows launchers need their own jli.dll, not our helper's.
                    if (System.getProperty("os.name").startsWith("Windows"))
                        vm.loadAgentPath(payload.getParent().resolve("pztools-attach-bootstrap.dll").toString());
                    vm.loadAgent(payload.getParent().resolve("pztools-save-bootstrap.jar").toString(), "BOOTSTRAP1:" + encoded);
                    endpoint = vm.getSystemProperties().getProperty(CONTROL_PROPERTY);
                }
                if (!"3".equals(vm.getSystemProperties().getProperty("pztools.bridge.bootstrap.api")))
                    throw new IOException("Restart the game to use the updated bridge; no save request was sent");
            } finally { vm.detach(); }
            if (endpoint == null) throw new IOException("Bootstrap is incompatible; restart the game with matching app/workers");
            String[] fields = endpoint.split(":", -1);
            if (fields.length != 4 || !fields[0].equals("1") || Long.parseLong(fields[1]) != pid
                    || !fields[3].matches("[0-9a-f]{64}")) throw new IOException("Invalid bootstrap endpoint");
            int controlPort = Integer.parseInt(fields[2]);
            if (controlPort < 1 || controlPort > 65535) throw new IOException("Invalid bootstrap port");
            try (var socket = new Socket()) {
                socket.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), controlPort), 2000);
                socket.setSoTimeout(3000);
                var out = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8), true);
                var in = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                out.println(fields[3] + "\t" + port + "\t" + args[3] + "\t" + encoded);
                // Fixed-size reply, never log the endpoint credential. An ambiguous dispatch is NOT retried.
                char[] response = new char[32];
                int count = 0, ch;
                while ((ch = in.read()) != -1 && ch != '\n') {
                    if (count == response.length) throw new IOException("Oversized bootstrap response");
                    if (ch != '\r') response[count++] = (char)ch;
                }
                if (!new String(response, 0, count).equals("ACCEPTED"))
                    throw new IOException("Bridge unavailable or busy; no save command sent. Restart the game after bootstrap updates.");
            }
        }
    }
}
