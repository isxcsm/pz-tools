# Windows USN journal

[Documentation index](README.md) · [User guide](../README.md)

The Windows change-tracking layer queries NTFS volume serial number, journal ID,
first readable USN, next USN, and lowest valid USN. An incremental checkpoint is
the tuple `(volume serial, journal ID, next USN)`; all three are validated before
reading. When USN cannot be used, backup falls back to a full scan with the
configured [content comparison](configuration.md).

Reads support record versions 2 and 3 with a fixed 1 MiB buffer. The parser checks
record lengths, versions, filename ranges, and USN boundaries before producing
typed records. V2 64-bit and V3 128-bit file/parent references normalize to
`UInt128`. Reads stop at the captured upper bound even if the journal grows
during the operation; records at or beyond that bound are ignored.

The delta planner consumes bounded batches rather than retaining the entire
journal interval. Rename state survives batch boundaries, and all hard-link paths
associated with a file reference remain tracked.

## Testing and permissions

Binary-parser tests need no elevated privileges. Live volume-query and bounded-read
tests run only with `PZTOOLS_TEST_USN=1`; disabled tests report skipped. The range
test also checks file references against `FILE_ID_INFO`.

Journal access on the development machine requires an elevated process, and direct
worker runs may have the same requirement. A future elevation helper would be a
deployment option; it must not own repository or telemetry state.
