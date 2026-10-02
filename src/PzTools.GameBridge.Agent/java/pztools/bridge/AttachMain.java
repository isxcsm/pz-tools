package pztools.bridge;

import com.sun.tools.attach.VirtualMachine;
import java.io.*;
import java.net.*;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;

/** Short-lived helper. Reuses one authenticated bootstrap; never re-loads on dispatch failure. */
public final class AttachMain {
    private static final String CONTROL_PROPERTY = "pztools.bridge.control.v1";
    public static void main(String[] args) throws Exception {
        if (args.length != 4 && !(args.length == 5 && (args[4].equals("WATCH") || args[4].equals("EXTENSIONS")))) throw new IllegalArgumentException("Expected pid, agent jar, port, token");
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
                        vm.loadAgentPath(attachable(payload.getParent().resolve("pztools-attach-bootstrap.dll")).toString());
                    vm.loadAgent(attachable(payload.getParent().resolve("pztools-game-bootstrap.jar")).toString(), "BOOTSTRAP1:" + encoded);
                    endpoint = vm.getSystemProperties().getProperty(CONTROL_PROPERTY);
                }
                if (!"11".equals(vm.getSystemProperties().getProperty("pztools.bridge.bootstrap.api")))
                    throw new IOException("Restart the game to use the updated bridge; no save request was sent");
            } finally { vm.detach(); }
            if (endpoint == null) throw new IOException("Bootstrap is incompatible; restart the game with matching app/workers");
            String[] fields = endpoint.split(":", -1);
            if (fields.length != 4 || !fields[0].equals("2") || Long.parseLong(fields[1]) != pid
                    || !fields[3].matches("[0-9a-f]{64}")) throw new IOException("Invalid bootstrap endpoint");
            int controlPort = Integer.parseInt(fields[2]);
            if (controlPort < 1 || controlPort > 65535) throw new IOException("Invalid bootstrap port");
            try (var socket = new Socket()) {
                socket.connect(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), controlPort), 2000);
                socket.setSoTimeout(5000);
                var out = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8), true);
                var in = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                out.println(fields[3] + "\t" + port + "\t" + args[3] + "\t" + encoded + (args.length == 5 ? "\t" + args[4] : ""));
                // Fixed-size reply, never log the endpoint credential. An ambiguous dispatch is NOT retried.
                char[] response = new char[32];
                int count = 0, ch;
                while ((ch = in.read()) != -1 && ch != '\n') {
                    if (count == response.length) throw new IOException("Oversized bootstrap response");
                    if (ch != '\r') response[count++] = (char)ch;
                }
                String status = new String(response, 0, count);
                if (status.equals("BUSY"))
                    throw new IOException("A prior request or runtime transition is still active. No save command sent; retry after it finishes.");
                if (status.equals("PAYLOAD_UNAVAILABLE"))
                    throw new IOException("Bridge payload is incomplete or incompatible. Restore matching deployment files; no save command was sent.");
                if (!status.equals("ACCEPTED"))
                    throw new IOException("Bridge rejected the connection. No save command was sent.");
            }
        }
    }

    /**
     * The game's JVM is handed the native bootstrap and the bootstrap jar by path, and misreads a path with letters
     * outside ASCII: the app in a folder named in Korean could not attach ("... was not loaded"). Such a file is
     * copied once, under its content's digest, to a folder whose path is plain ASCII, and handed over from there.
     * Everything after (the payload, the extensions) is read by Java from its own path and needs nothing of this.
     * With no such folder to be had, the file's own path is tried as before.
     */
    static Path attachable(Path file) throws Exception {
        if (ascii(file.toString())) return file;
        byte[] content = Files.readAllBytes(file);
        String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(content)).substring(0, 16);
        for (String root : new String[] { System.getenv("ProgramData"), System.getProperty("java.io.tmpdir"), System.getenv("PUBLIC") }) {
            if (root == null || root.isEmpty() || !ascii(root)) continue;
            Path directory = Path.of(root, "PzTools", "attach", digest);
            Path staged = directory.resolve(file.getFileName().toString());
            try {
                // A copy a running game holds open is already the same bytes, and is used as it is.
                if (Files.isRegularFile(staged) && Arrays.equals(Files.readAllBytes(staged), content)) return staged;
                Files.createDirectories(directory);
                Path partial = Files.createTempFile(directory, "staging", ".tmp");
                Files.write(partial, content);
                Files.move(partial, staged, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
                return staged;
            } catch (IOException | SecurityException unusable) { }
        }
        return file;
    }

    private static boolean ascii(String text) {
        for (int index = 0; index < text.length(); index++) if (text.charAt(index) > 0x7E) return false;
        return true;
    }
}
