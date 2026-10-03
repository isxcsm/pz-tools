package pztools.bridge.runtime;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;

/**
 * How long what the app asked of the game lasts, apart from the connections that carry its requests. A connection ends
 * often and comes back (the app's scheduler restarting, a game load); what was asked for need not end with it, and
 * must end once the app has gone, however it went. Each holder of such a right has a lease: it lasts while it is
 * renewed in time, and lapses otherwise.
 *
 * <p>An app run is named by an identifier it makes when it starts (32 hex digits), which tells it from an earlier or
 * later run of the app; the game knows nothing of its process. Any channel of that run renews its lease: the state
 * stream (WATCH) for as long as it is open, and each request that names it. What it asked for (the last minutes'
 * recording) follows the lease, with the term of {@link #APP_TERM}. A holder whose right must end with its own
 * connection (extension control) keeps a {@link Lease} of its own, with a short term, ended when the connection is.
 */
final class Leases {
    private Leases() { }

    /** A right that lasts while renewed within its term, until it lapses or is ended. */
    static final class Lease {
        private final LongSupplier clock;
        private final long term;
        private volatile long deadline;
        private volatile boolean ended;
        Lease(LongSupplier clock, long term) {
            this.clock = clock; this.term = term; deadline = clock.getAsLong() + term;
        }
        void renew() { if (!ended) deadline = clock.getAsLong() + term; }
        boolean lapsed() { return ended || clock.getAsLong() - deadline >= 0; }
        void end() { ended = true; }
    }

    /**
     * How long an app run's lease lasts unheard: long enough for its scheduler to restart or a game load to pass, short
     * enough that the game does not record for long for an app that has gone. A test sets it shorter.
     */
    static final long APP_TERM = TimeUnit.SECONDS.toNanos(Math.max(1, Long.getLong("pztools.bridge.lease.seconds", 120)));
    private static final Map<String, Lease> apps = new ConcurrentHashMap<>();

    static boolean validApp(String app) { return app != null && app.matches("[0-9a-f]{32}"); }

    /** Renews the lease of an app run: begun anew when it has none, or its last has lapsed. */
    static void renewApp(String app) {
        apps.compute(app, (key, lease) -> lease == null || lease.lapsed() ? new Lease(System::nanoTime, APP_TERM) : lease).renew();
        // Runs that have gone are forgotten, so the table stays as small as the runs still heard from.
        if (apps.size() > 1) apps.entrySet().removeIf(entry -> !entry.getKey().equals(app) && entry.getValue().lapsed());
    }

    /** Whether the app run still holds its lease. */
    static boolean appHolds(String app) {
        Lease lease = apps.get(app);
        return lease != null && !lease.lapsed();
    }
}
