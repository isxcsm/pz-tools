package pztools.bridge;

import com.sun.tools.attach.VirtualMachine;
import java.io.*;
import java.net.*;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;

/** Short-lived helper. Reuses one authenticated bootstrap; never re-loads on dispatch failure. */
public final class AttachMain {
    private static final String CONTROL_PROPERTY = "pztools.bridge.control.v1";
    /** The first line a failure prints, before its stack trace: the step it stopped at, then the error, for the app. */
    static final String FAILURE_MARK = "PZTOOLS-ATTACH-FAILED";
    private static String stage = "arguments";

    public static void main(String[] args) throws Exception {
        try { run(args); }
        catch (Exception failure) {
            String message = String.valueOf(failure.getMessage()).replace('\r', ' ').replace('\n', ' ');
            System.err.println(FAILURE_MARK + "\t" + stage + "\t" + failure.getClass().getName() + ": " + message);
            throw failure;
        }
    }

    private static void run(String[] args) throws Exception {
        if (args.length != 4 && !(args.length == 5 && (args[4].equals("WATCH") || args[4].equals("EXTENSIONS")))) throw new IllegalArgumentException("Expected pid, agent jar, port, token");
        long pid = Long.parseLong(args[0]);
        int port = Integer.parseInt(args[2]);
        if (pid <= 0 || port < 1 || port > 65535 || !args[3].matches("[0-9a-f]{64}"))
            throw new IllegalArgumentException("Invalid connection parameters");
        Path payload = Path.of(args[1]).toAbsolutePath().normalize();
        String encoded = Base64.getEncoder().encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8));
        // One small per-user lock serializes cold discovery/initialization across worker processes.
        // OS file locks are released when a helper is killed. Do not unlink the shared lock file.
        stage = "lock";
        Path directory = Path.of(System.getProperty("user.home"), ".pztools-bridge");
        Files.createDirectories(directory);
        if (Files.isSymbolicLink(directory)) throw new IOException("Linked bridge lock directory is not supported");
        try (var lockFile = FileChannel.open(directory.resolve("bootstrap.lock"),
                StandardOpenOption.CREATE, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
             var lock = lockFile.lock()) {
            stage = "attach";
            VirtualMachine vm = VirtualMachine.attach(Long.toString(pid));
            String endpoint;
            try {
                endpoint = vm.getSystemProperties().getProperty(CONTROL_PROPERTY);
                if (endpoint == null) {
                    // Embedded Windows launchers need their own jli.dll, not our helper's.
                    stage = "native-bootstrap";
                    if (System.getProperty("os.name").startsWith("Windows"))
                        vm.loadAgentPath(attachable(payload.getParent().resolve("pztools-attach-bootstrap.dll")).toString());
                    stage = "bootstrap";
                    vm.loadAgent(attachable(payload.getParent().resolve("pztools-game-bootstrap.jar")).toString(), "BOOTSTRAP1:" + encoded);
                    endpoint = vm.getSystemProperties().getProperty(CONTROL_PROPERTY);
                }
                stage = "bootstrap-version";
                if (!"11".equals(vm.getSystemProperties().getProperty("pztools.bridge.bootstrap.api")))
                    throw new IOException("Restart the game to use the updated bridge; no save request was sent");
            } finally { vm.detach(); }
            if (endpoint == null) throw new IOException("Bootstrap is incompatible; restart the game with matching app/workers");
            stage = "handshake";
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
     *
     * <p>The game loads what it is handed as code, so the copy must be one no other user can change: the user's
     * temporary folder if its path is ASCII (a user named in Korean has one that is not), else a folder of this user's
     * own under ProgramData. ProgramData lets every user create in it, so that folder is made writable by this user
     * alone, and an existing one, or an existing copy, is used only if this user owns it and no one else may write it.
     */
    static Path attachable(Path file) throws Exception {
        if (ascii(file.toString())) return file;
        byte[] content = Files.readAllBytes(file);
        String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(content)).substring(0, 16);
        String account = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
            .digest(System.getProperty("user.name", "").getBytes(StandardCharsets.UTF_8))).substring(0, 12);
        UserPrincipal self = null;
        for (String root : new String[] { System.getProperty("java.io.tmpdir"), System.getenv("ProgramData") }) {
            if (root == null || root.isEmpty() || !ascii(root)) continue;
            try {
                if (self == null) self = currentUser();
                Path base = Path.of(root, "PzTools", "attach", "u-" + account);
                if (!privateDirectory(base, self)) continue;
                Path directory = base.resolve(digest);
                Path staged = directory.resolve(file.getFileName().toString());
                if (!Files.isDirectory(directory)) Files.createDirectory(directory);
                if (!writableOnlyBy(directory, self)) continue;
                // A copy a running game holds open is already the same bytes, and is used as it is.
                if (Files.isRegularFile(staged, LinkOption.NOFOLLOW_LINKS) && writableOnlyBy(staged, self)
                        && Arrays.equals(Files.readAllBytes(staged), content)) return staged;
                Path partial = Files.createTempFile(directory, "staging", ".tmp");
                try {
                    Files.write(partial, content);
                    Files.move(partial, staged, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
                } finally { Files.deleteIfExists(partial); }
                if (writableOnlyBy(staged, self)) return staged;
            } catch (IOException | SecurityException | UnsupportedOperationException unusable) { }
        }
        return file;
    }

    // Who this helper runs as: the owner of a file it creates.
    private static UserPrincipal currentUser() throws IOException {
        Path probe = Files.createTempFile("pztools-owner", ".tmp");
        try { return Files.getOwner(probe); } finally { Files.deleteIfExists(probe); }
    }

    /** Makes the folder this user's alone, or checks that an existing one already is. */
    private static boolean privateDirectory(Path directory, UserPrincipal self) throws IOException {
        if (Files.isSymbolicLink(directory)) return false;
        if (!Files.isDirectory(directory)) {
            Files.createDirectories(directory.getParent());
            Files.createDirectory(directory);
            var acl = Files.getFileAttributeView(directory, AclFileAttributeView.class);
            if (acl == null) return false;
            acl.setAcl(java.util.List.of(AclEntry.newBuilder().setType(AclEntryType.ALLOW).setPrincipal(self)
                .setPermissions(java.util.EnumSet.allOf(AclEntryPermission.class))
                .setFlags(AclEntryFlag.FILE_INHERIT, AclEntryFlag.DIRECTORY_INHERIT).build()));
        }
        return writableOnlyBy(directory, self);
    }

    private static final java.util.Set<AclEntryPermission> WRITES = java.util.EnumSet.of(AclEntryPermission.WRITE_DATA,
        AclEntryPermission.APPEND_DATA, AclEntryPermission.WRITE_ACL, AclEntryPermission.WRITE_OWNER, AclEntryPermission.DELETE,
        AclEntryPermission.DELETE_CHILD, AclEntryPermission.WRITE_ATTRIBUTES, AclEntryPermission.WRITE_NAMED_ATTRS);

    /** Owned by this user, with no one else allowed to change it or what is in it. */
    private static boolean writableOnlyBy(Path path, UserPrincipal self) throws IOException {
        var view = Files.getFileAttributeView(path, AclFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
        if (view == null || !self.equals(view.getOwner())) return false;
        for (AclEntry entry : view.getAcl())
            if (entry.type() == AclEntryType.ALLOW && !self.equals(entry.principal())
                    && entry.permissions().stream().anyMatch(WRITES::contains)) return false;
        return true;
    }

    private static boolean ascii(String text) {
        for (int index = 0; index < text.length(); index++) if (text.charAt(index) > 0x7E) return false;
        return true;
    }
}
