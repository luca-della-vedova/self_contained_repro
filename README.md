:warn: AI generated :warn:

# Rust >= 1.90 Self-Contained Linker Reproduction

This repository provides a minimal reproducible example for the build failure encountered in CI when using `rules_rs` with Rust >= 1.90 on Linux `x86_64`.

## Error Message

```text
ERROR: external/rules_rs++rules_rust+rules_rust/util/process_wrapper/BUILD.bazel:4:36: Compiling Rust (without process_wrapper) bin @@rules_rs++rules_rust+rules_rust//util/process_wrapper:process_wrapper (6 files) [for tool] failed: (Exit 1): bootstrap_process_wrapper failed: error executing Rustc command (from target @@rules_rs++rules_rust+rules_rust//util/process_wrapper:process_wrapper)
  error: the self-contained linker was requested, but it wasn't found in the target's sysroot, or in rustc's sysroot
```

## Root Cause Analysis

### 1. The Upstream Rust >= 1.90 Target Spec Change
In Rust 1.90.0, the default target specification for `x86_64-unknown-linux-gnu` (`compiler/rustc_target/src/spec/base/linux_gnu.rs`) changed to enable LLD by default:
```rust
if option_env!("CFG_DEFAULT_LINKER_SELF_CONTAINED_LLD_CC").is_some() {
    base.linker_flavor = LinkerFlavor::Gnu(Cc::Yes, Lld::Yes);
    base.link_self_contained = crate::spec::LinkSelfContainedDefault::with_linker();
}
```
This enables `LinkSelfContainedComponents::LINKER` by default.

### 2. Linker Flavor Inference with `toolchains_llvm`
When `rules_rust` invokes `rustc` with an external C++ toolchain from `toolchains_llvm`, it passes:
```text
--codegen=linker=external/toolchains_llvm++llvm+llvm_toolchain/bin/cc_wrapper.sh
```
In `rustc`'s `compiler/rustc_target/src/spec/mod.rs:infer_linker_hints()`, the compiler checks the executable stem. Since `cc_wrapper` does not match `gcc`, `clang`, or `ld`, `rustc` falls back to the default target flavor, preserving `Lld::Yes`.

### 3. Missing `gcc-ld` in Hermetic Environments
In `compiler/rustc_codegen_ssa/src/back/link.rs:add_lld_args()`:
```rust
let self_contained_linker = self_contained_cli || self_contained_target;
if self_contained_linker && !sess.opts.cg.link_self_contained.is_linker_disabled() {
    let mut linker_path_exists = false;
    for path in sess.get_tools_search_paths(false) {
        let linker_path = path.join("gcc-ld");
        linker_path_exists |= linker_path.exists();
        ...
    }
    if !linker_path_exists {
        sess.dcx().emit_fatal(errors::SelfContainedLinkerMissing);
    }
}
```
`rustc` searches for a directory named `gcc-ld` in its sysroot search paths.

In `rules_rs`:
- The upstream Rust archive contains `lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld/`.
- In `rules_rs/rs/private/rustc_repository.bzl`, `gcc-ld` is placed inside the `:rust-lld` filegroup.
- In `rules_rs/rs/toolchains/declare_rustc_toolchains.bzl`, `linker = None` on Linux x86_64.
- Consequently, `:rust-lld` (and therefore `gcc-ld`) is **never declared as an input to any action**.

### 4. Why It Failed in CI but Passed on Local Workstations
- **In CI (RBE / Remote Execution):** Only explicitly declared action inputs are uploaded to the remote executor container. Since `gcc-ld` is not declared as an input, it does not exist in the executor filesystem. `rustc` emits `SelfContainedLinkerMissing`.
- **On Local Workstations:** Bazel's default `linux-sandbox` permits read access to the host filesystem (`/`). When `rustc` runs, `/proc/self/exe` resolves symlinks to the canonical location in `~/.cache/bazel/.../external/rules_rs++toolchains+rustc_linux_x86_64_1_93_0/bin/rustc`. From there, `rustc` finds `gcc-ld` on the host filesystem outside the sandbox, masking the bug.

## How to Reproduce

Run the reproduction script:
```bash
./repro.sh
```
This simulates the hermetic input environment of RBE by blocking the undeclared `bin/` directory from the host cache. The build fails with:
```text
error: the self-contained linker was requested, but it wasn't found in the target's sysroot, or in rustc's sysroot
```

## How to Verify the Fix
 
Run:
```bash
./repro.sh --fix
```
This points the `rules_rs` worktree to the commit containing the fix (`2d856b2`), which passes `-Clinker-features=-lld` on `x86_64-unknown-linux-gnu` for Rust >= 1.90:
```python
def _default_rustc_flags(version):
    if _channel(version) == "stable" and not versions.is_at_least("1.90.0", version):
        return []

    return select({
        "@rules_rs//rs/platforms/config:x86_64-unknown-linux-gnu": ["-Clinker-features=-lld"],
        "//conditions:default": [],
    })
```
Disabling `rustc`'s internal LLD feature prevents `rustc` from looking for `gcc-ld` in the sysroot, resolving the hermetic missing-input failure while preventing `rustc` from hijacking the C++ toolchain's configured linker.


