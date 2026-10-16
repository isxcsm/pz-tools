package pzext.launch;

import java.io.File;
import java.io.IOException;
import java.nio.file.FileSystems;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.AclEntry;
import java.nio.file.attribute.AclEntryFlag;
import java.nio.file.attribute.AclEntryPermission;
import java.nio.file.attribute.AclEntryType;
import java.nio.file.attribute.AclFileAttributeView;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFileAttributeView;
import java.nio.file.attribute.PosixFilePermission;
import java.nio.file.attribute.UserPrincipal;
import java.util.EnumSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Who the loader trusts with the files it runs (docs/loader.md): a folder is fit for it when it is owned by one of the
 * trusted accounts and no one else may change it. The install makes the install folder so (only the machine's
 * administrators write it) and the loader checks it again at every game start, before it loads anything from it: a
 * folder another account created or can write is a place to run code in the game. The trusted accounts are the
 * machine's administrators (found, not named, because their names depend on the language of Windows) and the accounts
 * the install settings list besides them (the tests).
 *
 * <p>Uses java.base alone: it runs inside the loader, before the game has set anything up.
 */
public final class Trust {
    private static final Set<AclEntryPermission> WRITES = EnumSet.of(AclEntryPermission.WRITE_DATA,
        AclEntryPermission.APPEND_DATA, AclEntryPermission.WRITE_ACL, AclEntryPermission.WRITE_OWNER, AclEntryPermission.DELETE,
        AclEntryPermission.DELETE_CHILD, AclEntryPermission.WRITE_ATTRIBUTES, AclEntryPermission.WRITE_NAMED_ATTRS);

    private Trust() { }

    /**
     * The accounts that may change the operating system's own folder (Windows: the owner of {@code %SystemRoot%} and
     * every account its list lets write there: the system, the administrators, the installer service). Whoever can
     * write there can already run code as anyone, so these are trusted with the install. Their well-known English names
     * are added in case the folder cannot be read (on Windows) and {@code root} on other systems.
     */
    public static Set<UserPrincipal> administrators() {
        var found = new LinkedHashSet<UserPrincipal>();
        boolean windows = File.separatorChar == '\\';
        try {
            String system = System.getenv("SystemRoot");
            if (windows && system != null && !system.isEmpty()) {
                Path folder = Path.of(system);
                var view = Files.getFileAttributeView(folder, AclFileAttributeView.class);
                if (view != null) {
                    found.add(view.getOwner());
                    for (AclEntry entry : view.getAcl())
                        if (entry.type() == AclEntryType.ALLOW && !entry.flags().contains(AclEntryFlag.INHERIT_ONLY) && writes(entry))
                            found.add(entry.principal());
                }
            }
        } catch (Throwable unreadable) { }
        for (String name : windows ? new String[] { "BUILTIN\\Administrators", "NT AUTHORITY\\SYSTEM", "NT SERVICE\\TrustedInstaller" } : new String[] { "root" })
            add(found, name);
        return found;
    }

    /** The administrators and the accounts named besides them (an account the machine does not know is left out). */
    public static Set<UserPrincipal> with(String... extra) {
        var found = administrators();
        for (String name : extra) add(found, name);
        return found;
    }

    private static void add(Set<UserPrincipal> found, String name) {
        try {
            if (name != null && !name.isEmpty()) found.add(FileSystems.getDefault().getUserPrincipalLookupService().lookupPrincipalByName(name));
        } catch (Throwable unknown) { }
    }

    private static boolean writes(AclEntry entry) {
        for (AclEntryPermission permission : entry.permissions()) if (WRITES.contains(permission)) return true;
        return false;
    }

    /** Whether the path is a link of any kind (a symbolic link or a junction), or not a plain folder or file. */
    public static boolean isLink(Path path) {
        try {
            var attributes = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
            return attributes.isSymbolicLink() || attributes.isOther();
        } catch (IOException | RuntimeException unreadable) { return true; }
    }

    /**
     * Null when the folder or file is fit: a plain one (not a link), owned by a trusted account and changeable by
     * trusted accounts alone; else what is wrong with it, in a line.
     */
    public static String problem(Path path, Set<UserPrincipal> trusted) throws IOException {
        var attributes = Files.readAttributes(path, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        if (attributes.isSymbolicLink() || attributes.isOther() || !(attributes.isDirectory() || attributes.isRegularFile()))
            return path + " is a link or not a plain folder or file";
        var acl = Files.getFileAttributeView(path, AclFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
        if (acl != null) return problem(path.toString(), acl.getOwner(), acl.getAcl(), trusted);
        var posix = Files.getFileAttributeView(path, PosixFileAttributeView.class, LinkOption.NOFOLLOW_LINKS);
        if (posix == null) return path + " has no owner or access list to check";
        var found = posix.readAttributes();
        if (!trusted.contains(found.owner())) return path + " is owned by " + found.owner().getName();
        if (found.permissions().contains(PosixFilePermission.GROUP_WRITE) || found.permissions().contains(PosixFilePermission.OTHERS_WRITE))
            return path + " may be changed by other accounts";
        return null;
    }

    /**
     * The same judgement on an owner and an access list that are already read (the part the tests drive without an
     * account of their own): an owner that is not trusted, or an entry that lets an account that is not trusted write,
     * is a problem. Entries only for what is made inside the folder (inherit-only) and refusals do not count.
     */
    public static String problem(String name, UserPrincipal owner, List<AclEntry> acl, Set<UserPrincipal> trusted) {
        if (!trusted.contains(owner)) return name + " is owned by " + owner.getName();
        for (AclEntry entry : acl)
            if (entry.type() == AclEntryType.ALLOW && !entry.flags().contains(AclEntryFlag.INHERIT_ONLY)
                && !trusted.contains(entry.principal()) && writes(entry))
                return name + " may be changed by " + entry.principal().getName();
        return null;
    }
}
