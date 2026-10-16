package pzext.install;

import java.io.IOException;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Set;
import pzext.launch.Trust;

/**
 * The install folder may be changed by the machine's administrators alone: what the game loads from it runs inside the
 * game ({@link Trust} says who is trusted, and the loader checks the same at every game start). These make the folder
 * and its parent, the shared {@code PZExtAPI} folder under ProgramData, so; set aside what another account created or
 * can write; and make the two files the game writes (the loader's log and the API's status) writable by the player's
 * account alone.
 */
final class Folders {
    /** What the player's account may do in the install folder: read and run what is there. */
    private static final Set<AclEntryPermission> READ = EnumSet.of(AclEntryPermission.READ_DATA, AclEntryPermission.READ_NAMED_ATTRS,
        AclEntryPermission.READ_ATTRIBUTES, AclEntryPermission.READ_ACL, AclEntryPermission.EXECUTE, AclEntryPermission.SYNCHRONIZE);
    /**
     * What the player's account may do with the log and the status file: write them whole (not remove, rename or change
     * their access list). The attributes and extended attributes are part of what a write opens a file for on Windows.
     */
    private static final Set<AclEntryPermission> WRITE_FILE = EnumSet.of(AclEntryPermission.WRITE_DATA, AclEntryPermission.APPEND_DATA,
        AclEntryPermission.WRITE_ATTRIBUTES, AclEntryPermission.WRITE_NAMED_ATTRS);
    private static final Set<AclEntryFlag> INHERIT = EnumSet.of(AclEntryFlag.FILE_INHERIT, AclEntryFlag.DIRECTORY_INHERIT);

    private Folders() { }

    /**
     * The player's account and the account this runs as. The player's is the one the game runs as when the caller says
     * so ({@code PZEXT_GAME_ACCOUNT}, read from the game's process), else the account this was started for (which an
     * elevated process keeps as its own), else the creator of a new file. The creator is the owner of what this makes:
     * the administrators' group in an elevated process, the account itself in one that is not.
     */
    static UserPrincipal[] principals() throws IOException {
        Path probe = Files.createTempFile("pzext-owner", ".tmp");
        UserPrincipal creator;
        try { creator = Files.getOwner(probe); } finally { Files.deleteIfExists(probe); }
        String domain = System.getenv("USERDOMAIN"), name = System.getenv("USERNAME");
        UserPrincipal user = lookup(System.getenv("PZEXT_GAME_ACCOUNT"));
        if (user == null && name != null && !name.isEmpty())
            user = lookup(domain == null || domain.isEmpty() ? name : domain + "\\" + name);
        return new UserPrincipal[] { user == null ? creator : user, creator };
    }

    private static UserPrincipal lookup(String account) {
        if (account == null || account.isEmpty()) return null;
        try { return FileSystems.getDefault().getUserPrincipalLookupService().lookupPrincipalByName(account); }
        catch (IOException unknown) { return null; }
    }

    /**
     * Makes the shared folder and the install folder fit (or leaves them so): owned by the trusted accounts, writable by
     * them alone, the install folder readable by the player. A folder a trusted account made whose access list lets
     * others write gets the right list again; one another account made (or a link) is moved aside under another name
     * (never entered, never deleted) and made again; when that cannot be done, the install is refused.
     * Refused too when what this makes would not be the trusted accounts' own (not an administrator's process).
     */
    static void claim(Path root, Set<UserPrincipal> trusted, UserPrincipal player) throws Exception {
        UserPrincipal creator = principals()[1];
        if (!trusted.contains(creator))
            throw new Install.Refused("not-administrator", "The install needs an administrator: what it makes here would be owned by "
                + creator.getName() + ", an account that may not own the files the game runs. Run it elevated.");
        Path shared = root.getParent();
        folder(shared, trusted, player, true);
        folder(root, trusted, player, false);
    }

    private static void folder(Path folder, Set<UserPrincipal> trusted, UserPrincipal player, boolean shared) throws Exception {
        if (Files.exists(folder, LinkOption.NOFOLLOW_LINKS)) {
            String problem;
            try { problem = Trust.problem(folder, trusted); }
            catch (IOException unreadable) { problem = folder + " cannot be read (" + unreadable.getMessage() + ")"; }
            if (problem == null && !Files.isDirectory(folder, LinkOption.NOFOLLOW_LINKS)) problem = folder + " is not a folder";
            if (problem != null) {
                // One of the trusted accounts made it, so only its list is wrong: only they could have changed it, and the list is
                // made again. One that anyone else made, or a link, is moved aside: what is in it is theirs.
                boolean ours = !Trust.isLink(folder) && Files.isDirectory(folder, LinkOption.NOFOLLOW_LINKS)
                    && trusted.contains(Files.getOwner(folder, LinkOption.NOFOLLOW_LINKS));
                if (ours) acl(folder).setAcl(entries(trusted, player, shared));
                else setAside(folder, problem);
            }
        }
        if (!Files.exists(folder, LinkOption.NOFOLLOW_LINKS)) {
            Files.createDirectories(folder.getParent());
            Files.createDirectory(folder);
            acl(folder).setAcl(entries(trusted, player, shared));
        } else if (shared) {
            allowRead(folder, trusted, player);
        }
        String problem = Trust.problem(folder, trusted);
        if (problem != null) throw new Install.Refused("unsafe-folder", problem);
        if (!shared && !readable(folder, trusted, player))
            throw new Install.Refused("unsafe-folder", folder + " cannot be read by the player's account");
    }

    /** The folder under another name beside it, for an administrator to look at; the install makes its own. */
    static Path setAside(Path folder, String why) throws Install.Refused {
        String stamp = DateTimeFormatter.ofPattern("yyyyMMddHHmmss").format(LocalDateTime.now());
        for (int number = 0; ; number++) {
            Path aside = folder.resolveSibling(folder.getFileName() + ".untrusted-" + stamp + (number == 0 ? "" : "-" + number));
            if (Files.exists(aside, LinkOption.NOFOLLOW_LINKS)) continue;
            try {
                Files.move(folder, aside, StandardCopyOption.ATOMIC_MOVE);
                return aside;
            } catch (IOException cannot) {
                throw new Install.Refused("unsafe-folder", why + ", and it could not be moved aside (" + cannot.getMessage()
                    + "). Remove or rename " + folder + " as an administrator.");
            }
        }
    }

    /** The trusted accounts everything; the player's account reads (and runs) what is there. */
    private static List<AclEntry> entries(Set<UserPrincipal> trusted, UserPrincipal player, boolean shared) {
        var entries = new ArrayList<AclEntry>();
        for (UserPrincipal principal : trusted) entries.add(entry(principal, EnumSet.allOf(AclEntryPermission.class), INHERIT));
        if (!trusted.contains(player)) entries.add(entry(player, READ, shared ? Set.of() : INHERIT));
        if (shared) {
            UserPrincipal users = lookup("BUILTIN\\Users");
            if (users != null && !trusted.contains(users)) entries.add(entry(users, READ, Set.of()));
        }
        return entries;
    }

    private static AclEntry entry(UserPrincipal principal, Set<AclEntryPermission> permissions, Set<AclEntryFlag> flags) {
        return AclEntry.newBuilder().setType(AclEntryType.ALLOW).setPrincipal(principal).setPermissions(permissions).setFlags(flags).build();
    }

    private static AclFileAttributeView acl(Path path) throws Exception {
        var view = Files.getFileAttributeView(path, AclFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
        if (view == null) throw new Install.Refused("unsafe-folder", "The file system of " + path + " has no access lists to make it safe with");
        return view;
    }

    /** The shared folder lets this player's account in, when no entry does yet (other players' installs share it). */
    private static void allowRead(Path folder, Set<UserPrincipal> trusted, UserPrincipal player) throws Exception {
        if (readable(folder, trusted, player)) return;
        var view = acl(folder);
        var entries = new ArrayList<>(view.getAcl());
        entries.add(entry(player, READ, Set.of()));
        view.setAcl(entries);
    }

    /** Whether an entry names the player's account (or the Users group) with the right to read, or the player is trusted. */
    private static boolean readable(Path folder, Set<UserPrincipal> trusted, UserPrincipal player) throws Exception {
        if (trusted.contains(player)) return true;
        UserPrincipal users = lookup("BUILTIN\\Users");
        for (AclEntry entry : acl(folder).getAcl())
            if (entry.type() == AclEntryType.ALLOW && !entry.flags().contains(AclEntryFlag.INHERIT_ONLY)
                && (player.equals(entry.principal()) || (users != null && users.equals(entry.principal())))
                && entry.permissions().contains(AclEntryPermission.READ_DATA)) return true;
        return false;
    }

    /** Whether a copied file is fit to be loaded: the trusted accounts' own, and readable by the player. */
    static String fit(Path file, Set<UserPrincipal> trusted, UserPrincipal player) throws Exception {
        String problem = Trust.problem(file, trusted);
        if (problem == null && !readable(file, trusted, player)) problem = file + " cannot be read by the player's account";
        return problem;
    }

    /**
     * A file the game writes (the loader's log, the API's status), there and empty when the install made it, and
     * writable whole by the player's account alone: the folder it is in is not.
     */
    static void gameFile(Path file, Set<UserPrincipal> trusted, UserPrincipal player) throws Exception {
        if (Files.exists(file, LinkOption.NOFOLLOW_LINKS) && !Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) Files.delete(file);
        if (!Files.exists(file, LinkOption.NOFOLLOW_LINKS)) Files.createFile(file);
        var entries = new ArrayList<AclEntry>();
        for (UserPrincipal principal : trusted) entries.add(entry(principal, EnumSet.allOf(AclEntryPermission.class), Set.of()));
        if (!trusted.contains(player)) {
            var permissions = EnumSet.copyOf(READ);
            permissions.addAll(WRITE_FILE);
            entries.add(entry(player, permissions, Set.of()));
        }
        acl(file).setAcl(entries);
    }

    static boolean ascii(String text) {
        for (int index = 0; index < text.length(); index++) if (text.charAt(index) > 0x7E) return false;
        return true;
    }
}
