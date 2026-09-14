# AGENT.md — libsgc-c

## Purpose
C ABI library `sgc` exporting `libsgc.a` (static) and `libsgc.so` (shared), with headers `include/libsgc.h` / `include/sgc.hpp`. Thin, panic-safe wrappers over the Rust core in `libsgc-rs`. Every public function returns `0`/`-1` (or handle/`NULL`) and writes a NUL-terminated error message — no panics cross the C ABI (`catch_unwind` at every entry point).

## Architecture
- **C ABI entry points** — all functions use `#[unsafe(no_mangle)]` `extern "C"`; the crate name is `sgc`; link with `-lsgc`
- **Opaque client handle** — `sgc_client` is an opaque `struct`; constructed by `sgc_connect`, consumed by `sgc_release` — one thread per client
- **Ownership rules** (mirrored in `include/libsgc.h`):
  - client handle is opaque, created by `sgc_connect`, consumed by `sgc_release`
  - fd in a `GRANTED` event and the fd from `sgc_fd` are owned by the caller (close them)
  - the array from `sgc_advertised` is `malloc`'d — free it with `sgc_free`
- **C++ wrapper** — `include/sgc.hpp` wraps the C ABI; C++ consumers should use that, not the C API directly
- **Round-trip mappings** — `sgc_resource` (kind + index) <-> `libsgc_rs::Resource`; `sgc_event` <-> `libsgc_rs::SgcEvent`. The library's `SgcEvent::Advertised` (the server pushing a changed resource list, e.g. a device plugged in while the client runs) maps to `SGC_EVENT_ADVERTISED`, which carries no resource (`kind`/`index` `-1`, no fd). The arm refreshes the handle's cached list — what `sgc_advertised` returns — and reports the event, so a C client can take the entries that are new to it. The mapping match is exhaustive: a new `SgcEvent` variant does not compile here until its arm lands.

## Rust Best Practices (per rust-skills, applied to C FFI boundary)
- [`unsafe-safety-comment`] — Write a `// SAFETY:` comment above every `unsafe` block and a `# Safety` section in every `unsafe fn`; every C function touching raw fds/pointers documents its safety invariant
- [`unsafe-minimize-scope`] — Keep `unsafe` blocks as small as possible — mark only the operation that requires unsafety, not the surrounding safe code; e.g. `OwnedFd::from_raw_fd()` is the only unsafe op, wrapped in `abi_int`
- [`unsafe-miri-ci`] — Run `cargo miri test` in CI for every crate that contains `unsafe` code
- [`unsafe-maybeuninit`] — Use `MaybeUninit<T>` for uninitialized memory; never use `mem::uninitialized()` or `mem::zeroed()` for types with validity invariants
- [`unsafe-extern-block`] — In Rust 2024, wrap `extern` blocks in `unsafe extern { }` and annotate each item as `safe` or `unsafe`
- [`unsafe-send-sync-manual`] — Document the invariants when manually implementing `Send` or `Sync`; prefer letting the compiler derive them automatically
- [`err-result-over-panic`] — C functions return `0`/`-1` with error text in buf; never panic across the ABI
- [`err-lowercase-msg`] — Error messages start lowercase, no trailing punctuation (enforced by `set_err`)
- [`num-nonzero`] — Use `NonZero*` types to forbid zero and unlock niche optimization; C ABI uses `c_int` kind/index, zero-encoded values are rejected
- [`api-from-not-into`] — Implement `From<T>`, not `Into<U>` — the Rust side implements `From<Resource>` conversions, C side delegates
- [`api-must-use`] — Mark C functions with `#[must_use]` context where return values signal success/failure; C convention is return `0` on success, `-1` on error
- [`doc-all-public`] — Document all public items; C functions have doc comments above the `#[unsafe(no_mangle)]` declaration
- [`doc-safety-section`] — Include `# Safety` section for unsafe functions (every `unsafe fn` and `unsafe` block)
- [`doc-errors-section`] — Include `# Errors` section documenting error-buffer writing behavior
- [`lint-unsafe-doc`] — Require documentation for unsafe blocks; every `unsafe` in ffi.rs has a `// SAFETY:` comment
- [`anti-unwrap-abuse`] — Don't use `.unwrap()` in production code — all fallible fns use `catch_unwind` + error buf
- [`anti-stringly-typed`] — Don't use strings where enums or newtypes would provide type safety — C `sgc_resource` uses kind+index, which is the flat encoding of the 3-level Rust enum

## Key ABI Functions
- `sgc_connect(err, err_len)` — connect to `@sgc`, return opaque handle or NULL with error msg
- `sgc_advertised(c, out, count)` — copy advertised resources into malloc'd array; caller frees with `sgc_free`
- `sgc_free(p)` — free pointer previously returned by `sgc_advertised` (plain `malloc`/`free` pairing)
- `sgc_acquire(c, r, err, err_len)` — request resource; block until server answers; return 0 on grant
- `sgc_pump(c, timeout_ms, out, err, err_len)` — drive protocol: wait for one event; returns 1 if event stored
- `sgc_fd(c, r, err, err_len)` — borrow resource: returns a dup of the held fd; -1 with error if not held
- `sgc_release(c)` — tear down session; `NULL` is a no-op; handle must not be used afterwards

## C/C++ Usage Notes
- The C API is **panic-safe**: every entry point is wrapped in `catch_unwind`; a panic becomes an error message in the buf, process continues
- fd ownership: the fd returned by `sgc_pump` (GRANTED kind) and the fd from `sgc_fd` are owned by the caller — close them when done
- `sgc_advertised` returns a `malloc`'d array; free with `sgc_free`, NOT `free()` directly
- Resource round-trip: `sgc_resource { kind, index }` <-> `Resource`; invalid encodings (unknown kind, index out of u8 range, negative) are rejected
- Threading: one thread per client handle; the underlying `SgcClient` is single-threaded — do not share a handle across threads

## Common Pitfalls to Avoid
- ❌ Do NOT call `.unwrap()` or panic across the C ABI — every function uses `catch_unwind` + error buffer; a panic becomes an error string
- ❌ Do NOT forget to free the array from `sgc_advertised` with `sgc_free` — memory leak
- ❌ Do NOT share a `sgc_client` handle across threads — the underlying client is single-threaded; create one handle per thread
- ❌ Do NOT ignore the return value — `0` = success, `-1` = failure; error text is written to the `err` buffer
- ❌ Do NOT assume fd ownership is shared — each caller owns their fd; closing the canonical fd does not close dups, but the library drops the canonical on revoke/disconnect
- ❌ Do NOT use `mem::zeroed()` or `mem::uninitialized()` for types with validity invariants — use `MaybeUninit` instead
- ❌ Do NOT mix `sgc_resource` kind values arbitrarily — kind+index must encode a valid `Resource` variant; use the round-trip mappings

## Build & Linkage
```sh
just                     # release build (host target)
just build-gnu-aarch64   # board: glibc
just build-musl-aarch64  # board: fully static musl
just dist-gnu-aarch64    # + libraries/headers + strip into ./dist
just packages            # all four installable .debs into target/debian/
just ci                  # the gate: fmt + clippy + tests + packages
```

- Link with `-lsgc` (shared) or use `libsgc.a` (static)
- For musl targets: fully static; for gnu targets: dynamically linked
- Cross-compile: `.cargo/config.toml` sets the `linker` for `aarch64-unknown-linux-gnu` (aarch64-linux-gnu-gcc) and `aarch64-unknown-linux-musl` (aarch64-unknown-linux-musl-gcc), and adds `crt-static` for x86_64 musl. The host target needs no section; only the cdylib's final link uses the cross linker.
- The `cdylib` crate-type produces `libsgc.so`; `staticlib` produces `libsgc.a`. musl targets get the archive only — rustc drops `cdylib` for them ("unsupported crate type").
- Clippy's `not_unsafe_ptr_arg_deref` is allowed crate-wide in `lib.rs` on purpose: the C ABI entry points stay safe functions that validate their pointers and report errors, because C callers cannot express Rust's `unsafe` marker.

## Packaging & CI
`just ci` is the gate: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, then every package flavor. It is just recipes on purpose (no GitHub Actions workflow), so the same command runs on a workstation and on any runner.

Two packages per glibc flavor, six `.debs` from `just packages` into `target/debian/`:

| package | ships | recipes |
|---|---|---|
| `libsgc` (runtime) | `/usr/lib/libsgc.so.0` | `package-runtime-x86_64`, `package-runtime-aarch64` |
| `libsgc-dev` | headers, `/usr/lib/libsgc.a`, `/usr/lib/libsgc.so` symlink | `package-gnu-x86_64`, `package-gnu-aarch64` |
| `libsgc-dev-musl` | headers, `/usr/lib/libsgc.a` | `package-musl-x86_64`, `package-musl-aarch64` |

The split is held by the SONAME: the object is linked with `-Wl,-soname,libsgc.so.0` (`.cargo/config.toml`), so `-lsgc` resolves through the dev package's symlink and the binary records `DT_NEEDED libsgc.so.0`, which only the runtime package provides. Removing the runtime package while a client is installed: `dpkg -r libsgc` is refused (`libsgc-dev depends on libsgc`), and force-removing it makes the client die with `error while loading shared libraries: libsgc.so.0`.

The flavor must match how the consumer links — a glibc program cannot link the musl archive — and each packages pairs with the daemon of the same linkage: `libsgc` / `libsgc-dev` → `simple-graphics-controller`, `libsgc-dev-musl` → `simple-graphics-controller-musl`.

Rules that bite:

- musl has no runtime package: rustc drops the `cdylib` crate type for musl targets, so there is no `libsgc.so` to ship there.
- `$auto` contributes nothing to these packages, because dpkg-shlibdeps only reads binaries. The runtime package states `libc6, libgcc-s1` explicitly; the dev package states `libsgc` and the daemon.
- The dev package's symlink is declared as a table — `{ dest = "usr/lib/libsgc.so", link_name = "libsgc.so.0" }` — because its target does not exist in this repository (it comes from the runtime package), so a path-based asset cannot express it. `dest` is the link, `link_name` is the target.
- The musl flavor carries its own package name. cargo-deb derives the output filename from `name_version_arch` whatever `--variant` says, and it rewrites `target/debian` while packaging, so two flavors for one architecture would be the same file.
- glibc and musl each declare `Conflicts`/`Replaces` on the other. Declared one-sided, the swap works in one direction and fails in the other with a file conflict on the shared paths.
- Swapping a family with plain `dpkg -i` needs one command with the dependents listed first (`libsgc-dev-musl` before `simple-graphics-controller-musl`): dpkg will not remove a package another installed package still depends on. `apt` orders this itself.
- The archive asset is written as `target/release/libsgc.a`, not `target/<triple>/release/libsgc.a`: cargo-deb treats a leading `target/release/` as target-relative and resolves it per architecture under `--target`.