package pzext.install;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.util.*;
import pzext.launch.Trust;

/**
 * Who the loader and the install trust, without an account of its own to be another user and without an elevated
 * process: the judgement on an owner and an access list (accounts made up here), then the parts that need the file
 * system (the real owner and list of a folder this process makes, a junction, the file the game writes under the access
 * list the install gives it). Called by {@link InstallTest}.
 */
final class TrustTest {
    /** An account that exists nowhere: equal when the name is. */
    private record Account(String name) implements UserPrincipal {
        @Override public String getName() { return name; }
    }

    private static final UserPrincipal ADMIN = new Account("admins"), PLAYER = new Account("player"), OTHER = new Account("other");
    private static final Set<UserPrincipal> TRUSTED = Set.of(ADMIN);
    private static final Set<AclEntryFlag> NONE = Set.of(), THIS_INHERIT_ONLY = Set.of(AclEntryFlag.INHERIT_ONLY);

    static void run(Path work) throws Exception {
        policy();
        Files.createDirectories(work);
        files(work);
        System.out.println("TrustTest passed");
    }

    private static AclEntry allow(UserPrincipal who, Set<AclEntryFlag> flags, AclEntryPermission... permissions) {
        return entry(AclEntryType.ALLOW, who, flags, permissions);
    }

    private static AclEntry entry(AclEntryType type, UserPrincipal who, Set<AclEntryFlag> flags, AclEntryPermission... permissions) {
        return AclEntry.newBuilder().setType(type).setPrincipal(who).setFlags(flags).setPermissions(permissions).build();
    }

    private static String judge(UserPrincipal owner, AclEntry... acl) {
        return Trust.problem("folder", owner, List.of(acl), TRUSTED);
    }

    private static void policy() {
        var all = EnumSet.allOf(AclEntryPermission.class).toArray(AclEntryPermission[]::new);
        // The trusted account owns it and holds it; the player reads and runs it.
        assert judge(ADMIN, allow(ADMIN, NONE, all), allow(PLAYER, NONE, AclEntryPermission.READ_DATA, AclEntryPermission.EXECUTE)) == null;
        assert judge(ADMIN) == null : "an empty list is no one's write";
        // An owner that is not trusted (it can write the list), however the list looks.
        String owned = judge(PLAYER, allow(ADMIN, NONE, all));
        assert owned != null && owned.contains("owned by player") : owned;
        // Each way to change a folder or the files in it, for an account that is not trusted.
        for (AclEntryPermission write : new AclEntryPermission[] { AclEntryPermission.WRITE_DATA, AclEntryPermission.APPEND_DATA,
            AclEntryPermission.WRITE_ACL, AclEntryPermission.WRITE_OWNER, AclEntryPermission.DELETE, AclEntryPermission.DELETE_CHILD,
            AclEntryPermission.WRITE_ATTRIBUTES, AclEntryPermission.WRITE_NAMED_ATTRS }) {
            String problem = judge(ADMIN, allow(ADMIN, NONE, all), allow(OTHER, NONE, AclEntryPermission.READ_DATA, write));
            assert problem != null && problem.contains("may be changed by other") : write + ": " + problem;
        }
        // Not a way: reading, running, an entry for what is made inside the folder only, a refusal, a trusted account's write.
        assert judge(ADMIN, allow(OTHER, NONE, AclEntryPermission.READ_DATA, AclEntryPermission.EXECUTE, AclEntryPermission.READ_ACL,
            AclEntryPermission.READ_ATTRIBUTES, AclEntryPermission.SYNCHRONIZE)) == null;
        assert judge(ADMIN, allow(OTHER, THIS_INHERIT_ONLY, AclEntryPermission.WRITE_DATA)) == null : "CREATOR OWNER-like entries for children";
        assert judge(ADMIN, entry(AclEntryType.DENY, OTHER, NONE, AclEntryPermission.WRITE_DATA)) == null;
        assert judge(ADMIN, allow(ADMIN, NONE, AclEntryPermission.WRITE_DATA, AclEntryPermission.DELETE_CHILD)) == null;
        // The same entry that is only for children becomes a problem the moment it is for the folder too.
        assert judge(ADMIN, allow(OTHER, Set.of(AclEntryFlag.FILE_INHERIT), AclEntryPermission.WRITE_DATA)) != null;
    }

    private static void files(Path work) throws Exception {
        UserPrincipal user = Files.getOwner(Files.createDirectories(work));
        boolean windows = System.getProperty("os.name").startsWith("Windows");
        Set<UserPrincipal> trusted = Trust.with(user.getName());
        Set<UserPrincipal> administrators = Trust.administrators();
        assert !administrators.isEmpty() : "no administrators found";
        // The folder this process made: its real owner and list.
        Path folder = Files.createDirectory(work.resolve("folder"));
        var view = Files.getFileAttributeView(folder, AclFileAttributeView.class);
        if (view != null) {
            view.setAcl(List.of(allow(user, NONE, EnumSet.allOf(AclEntryPermission.class).toArray(AclEntryPermission[]::new))));
            assert Trust.problem(folder, trusted) == null : Trust.problem(folder, trusted);
            if (!administrators.contains(user)) {
                String problem = Trust.problem(folder, administrators);
                assert problem != null && problem.contains("is owned by"): problem;
            }
            // Another account may write it.
            if (windows) {
                var users = FileSystems.getDefault().getUserPrincipalLookupService().lookupPrincipalByName("BUILTIN\\Users");
                var open = new ArrayList<>(view.getAcl());
                open.add(allow(users, NONE, AclEntryPermission.WRITE_DATA));
                view.setAcl(open);
                String problem = Trust.problem(folder, trusted);
                assert problem != null && problem.contains("may be changed by BUILTIN\\Users") : problem;
            }
        }
        if (windows) {
            // A junction is a link: no install folder, never entered by the uninstall.
            Path victim = Files.createDirectory(work.resolve("victim"));
            Files.writeString(victim.resolve("keep.txt"), "kept");
            Path tree = Files.createDirectory(work.resolve("tree"));
            Files.writeString(tree.resolve("own.txt"), "own");
            Path junction = tree.resolve("junction");
            new ProcessBuilder("cmd", "/c", "mklink", "/J", junction.toString(), victim.toString()).redirectErrorStream(true).start().getInputStream().readAllBytes();
            assert Trust.isLink(junction) && !Trust.isLink(victim);
            String problem = Trust.problem(junction, trusted);
            assert problem != null && problem.contains("link") : problem;
            Install.deleteTree(tree);
            assert !Files.exists(tree) : "the tree stayed";
            assert Files.readString(victim.resolve("keep.txt")).equals("kept") : "the uninstall followed a junction";

            // The file the game writes: the player's account writes it whole and appends to it, and holds no right to
            // remove it, rename it or change who may. (The folder it is in would not let the player create or remove files.)
            if (!administrators.contains(user)) {
                Path log = work.resolve("loader.log");
                Folders.gameFile(log, administrators, user);
                var acl = Files.getFileAttributeView(log, AclFileAttributeView.class).getAcl();
                for (AclEntry entry : acl)
                    if (entry.principal().equals(user)) {
                        for (var forbidden : List.of(AclEntryPermission.DELETE, AclEntryPermission.WRITE_ACL, AclEntryPermission.WRITE_OWNER, AclEntryPermission.DELETE_CHILD))
                            assert !entry.permissions().contains(forbidden) : "the player may " + forbidden;
                        assert entry.permissions().contains(AclEntryPermission.WRITE_DATA) && entry.permissions().contains(AclEntryPermission.READ_DATA);
                    }
                for (AclEntry entry : acl)
                    assert entry.principal().equals(user) || administrators.contains(entry.principal()) : "an entry for " + entry.principal();
                // As the loader writes its log (first line, then later lines) and the API its status (in place).
                Files.writeString(log, "first\n", StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
                Files.writeString(log, "second\n", StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND, LinkOption.NOFOLLOW_LINKS);
                assert Files.readString(log).equals("first\nsecond\n");
                Files.write(log, "status\n".getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING,
                    StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
                assert Files.readString(log).equals("status\n");
            }
        }

        // A folder that is not fit is moved aside, never entered; one that cannot be moved aside is a refusal.
        Path bad = Files.createDirectory(work.resolve("bad"));
        Files.writeString(bad.resolve("inside.txt"), "x");
        Path aside = Folders.setAside(bad, "test");
        assert !Files.exists(bad) && Files.readString(aside.resolve("inside.txt")).equals("x") : aside;
        assert aside.getFileName().toString().startsWith("bad.untrusted-") : aside;
        assert Folders.setAside(Files.createDirectory(work.resolve("bad")), "test") != aside;
        try { Folders.setAside(work.resolve("not-there"), "test"); throw new AssertionError("moved aside what is not there"); }
        catch (Install.Refused refused) { assert refused.code.equals("unsafe-folder") : refused.code; }
    }
}
