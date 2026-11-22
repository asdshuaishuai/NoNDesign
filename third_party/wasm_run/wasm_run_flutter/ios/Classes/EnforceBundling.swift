// Vendored adjustment (NoNDesign, batch 01).
//
// Upstream's stub calls `dummy_method_to_enforce_bundling()`, an FRB symbol that
// is only resolvable when the Rust library is *statically* linked into the pod.
// This project vendors the prebuilt *dynamic* library instead (`wasm_run`'s
// build hook bundles `libwasm_run_dart.dylib` through native assets), so the
// stub must not reference Rust symbols — otherwise the iOS link fails with
// undefined `_wire_*` symbols.
//
// The symbol below keeps the pod non-empty; it is never called.
public func wasmRunFlutterRegisterBundledLibrary() -> Int64 { 0 }
