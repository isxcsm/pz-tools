package pztools.extensions.runtime;

import pztools.extensions.api.ContinuousModules;

/**
 * Control of one continuous module among several. The resident contract
 * ({@link ContinuousModules}) addresses a module only when applying; asking for the state of one
 * module, or turning one off while the others carry on, is this host's addition.
 *
 * <p>It lives in the replaceable runtime rather than the resident contract so that a running game
 * picks it up without a restart. The control channel is loaded separately and reaches these two
 * methods by name.
 */
public interface ModuleControl {
    /** The named module's state, or Disabled when it was never applied. Host-wide faults show through. */
    ContinuousModules.Status status(String moduleId);
    /** Retires the named module only. The others keep their generation, configuration and revision. */
    ContinuousModules.Status deactivate(String moduleId, String reason);
}
