package pzext.install;

import java.io.IOException;
import java.nio.file.*;
import java.nio.file.attribute.*;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Set;

/**
 * The install folder may be changed only by the player's account and the administrators: what the game loads from it
 * runs inside the game. These make the folder so and check every file copied into it.
 */
final class Folders {
    private static final Set<AclEntryPermission> WRITES = EnumSet.of(AclEntryPermission.WRITE_DATA,
        AclEntryPermission.APPEND_DATA, AclEntryPermission.WRITE_ACL, AclEntryPermission.WRITE_OWNER, AclEntryPermission.DELETE,
        AclEntryPermission.DELETE_CHILD, AclEntryPermission.WRITE_ATTRIBUTES, AclEntryPermission.WRITE_NAMED_ATTRS);

    private Folders() { }

    /**
     * The player's account and the account this runs as. The player's is the one the game runs as when the caller says
     * so ({@code PZEXT_GAME_ACCOUNT}, read from the game's process), else the account this was started for (which an
     * elevated process keeps as its own), else the creator of a new file.
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

    /** Makes the folder, open to those accounts alone, when it is not there; whether it is safe. */
    static boolean privateDirectory(Path directory, UserPrincipal[] owners) throws IOException {
        if (Files.isSymbolicLink(directory)) return false;
        if (!Files.isDirectory(directory)) {
            Files.createDirectories(directory.getParent());
            Files.createDirectory(directory);
            var acl = Files.getFileAttributeView(directory, AclFileAttributeView.class);
            if (acl == null) return false;
            var entries = new ArrayList<AclEntry>();
            for (UserPrincipal principal : owners[0].equals(owners[1]) ? List.of(owners[0]) : List.of(owners[0], owners[1]))
                entries.add(AclEntry.newBuilder().setType(AclEntryType.ALLOW).setPrincipal(principal)
                    .setPermissions(EnumSet.allOf(AclEntryPermission.class))
                    .setFlags(AclEntryFlag.FILE_INHERIT, AclEntryFlag.DIRECTORY_INHERIT).build());
            acl.setAcl(entries);
        }
        return safe(directory, owners);
    }

    /** Owned by one of the accounts, writable by no one else, readable by the player. */
    static boolean safe(Path path, UserPrincipal[] owners) throws IOException {
        var view = Files.getFileAttributeView(path, AclFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
        if (view == null || !trusted(owners, view.getOwner())) return false;
        boolean readable = false;
        for (AclEntry entry : view.getAcl()) {
            if (entry.type() != AclEntryType.ALLOW) continue;
            if (!trusted(owners, entry.principal()) && entry.permissions().stream().anyMatch(WRITES::contains)) return false;
            if (owners[0].equals(entry.principal()) && entry.permissions().contains(AclEntryPermission.READ_DATA)) readable = true;
        }
        return readable;
    }

    private static boolean trusted(UserPrincipal[] owners, UserPrincipal principal) {
        return owners[0].equals(principal) || owners[1].equals(principal);
    }

    static boolean ascii(String text) {
        for (int index = 0; index < text.length(); index++) if (text.charAt(index) > 0x7E) return false;
        return true;
    }
}
