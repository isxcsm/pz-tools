package pztools.extensions.runtime;

import pztools.extensions.api.SaveTask;

/** Optional replaceable-host capability; completion observation itself remains side-effect free.
 * The bridge resolves this interface once, before admission, across the sibling loader boundary.
 * It is not part of the resident bootstrap ABI.
 */
public interface CooperativeTask extends SaveTask {
    void advanceOnGameThread();
}
