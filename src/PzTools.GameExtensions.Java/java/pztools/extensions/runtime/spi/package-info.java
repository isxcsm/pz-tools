/**
 * What a module may use from the replaceable extension runtime, besides the resident API in
 * {@code pztools.extensions.api} and the key measurement in {@code pztools.extensions.runtime.input}.
 * The host's own classes in {@code pztools.extensions.runtime} are not a module contract; only the
 * entry point the bootstrap loads and the contracts the bridge calls are public there.
 */
package pztools.extensions.runtime.spi;
