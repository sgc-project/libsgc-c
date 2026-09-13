# Packaging

`libsgc-c` builds a static archive and a shared object, exported through the C and
C++ headers. They ship as two packages per glibc flavor:

    libsgc       runtime   /usr/lib/libsgc.so.0            the object, nothing else
    libsgc-dev   dev       /usr/include/libsgc.h           C header
                           /usr/include/sgc.hpp            C++ header
                           /usr/lib/libsgc.a               static archive
                           /usr/lib/libsgc.so -> libsgc.so.0   link-time symlink

The split is held together by the SONAME. The object is linked with
`-Wl,-soname,libsgc.so.0` (in `.cargo/config.toml`), so a consumer linking
`-lsgc` resolves through the dev package's symlink and the resulting binary
records `DT_NEEDED libsgc.so.0` - a name only the runtime package provides. The
shipped file is named after the soname itself, the way `libssl3` ships
`libssl.so.3`, so the patch version never appears in a filename and a version
bump does not touch packaging. Raising the ABI number means touching three
places: the soname in `.cargo/config.toml`, the runtime asset in `Cargo.toml` and
the symlink target in the dev assets.

## Recipes

| recipe | target | package |
|---|---|---|
| `package-gnu-x86_64` | x86_64-unknown-linux-gnu | `libsgc-dev` |
| `package-runtime-x86_64` | x86_64-unknown-linux-gnu | `libsgc` |
| `package-musl-x86_64` | x86_64-unknown-linux-musl | `libsgc-dev-musl` |
| `package-gnu-aarch64` | aarch64-unknown-linux-gnu | `libsgc-dev` |
| `package-runtime-aarch64` | aarch64-unknown-linux-gnu | `libsgc` |
| `package-musl-aarch64` | aarch64-unknown-linux-musl | `libsgc-dev-musl` |

`just packages` builds all six into `target/debian/`; `just ci` runs the gate
(`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`)
and then all six. On a device:

    dpkg -i libsgc_*_arm64.deb libsgc-dev_*_arm64.deb
    dpkg -L libsgc-dev

## Which flavor to install

The archive is built per target, so the flavor has to match how the consumer
links: a glibc program cannot link the musl archive, and the reverse. Each
package pairs with the daemon of the same linkage, because the library is what a
client links and the daemon is what it talks to:

    libsgc + libsgc-dev    -> simple-graphics-controller
    libsgc-dev-musl        -> simple-graphics-controller-musl

glibc and musl are **alternatives**, not companions: they install onto the same
paths, so installing one over the other replaces it. Both declare the conflict,
so the swap works in both directions.

Swapping a family with `dpkg -i` needs the whole family in one command, with the
dependent packages listed first:

    dpkg -i libsgc-dev-musl_*_arm64.deb simple-graphics-controller-musl_*_arm64.deb

dpkg refuses to remove a package while an installed package still depends on it,
so listing a dependency first fails with `conflicting packages - not installing
...` / `... depends on ...`. With the dependents first, dpkg schedules their
replacement, which frees the dependency. `apt` resolves the ordering itself.

## Rules that bite

- musl has **no runtime package**: rustc drops the `cdylib` crate type for musl
  targets (`dropping unsupported crate type cdylib`), so there is no `libsgc.so`
  to ship. A musl consumer links the archive.
- `$auto` contributes nothing to these packages, because dpkg-shlibdeps only
  reads binaries. The runtime package states `libc6, libgcc-s1` (what the
  object's `DT_NEEDED` asks for), the dev package states `libsgc` and the daemon.
- The dev package's symlink is declared as a table, not a file path:
  `{ dest = "usr/lib/libsgc.so", link_name = "libsgc.so.0" }`. `dest` is the link
  that gets created, `link_name` is what it points at. The target deliberately
  does not exist in this repository - it comes from the runtime package - so a
  path-based asset cannot express it.
- The musl flavors carry their own package name. cargo-deb derives the output
  filename from `name_version_arch` whatever `--variant` says, and it rewrites
  `target/debian` while packaging, so two flavors for one architecture would be
  the same file.
- The archive asset is written as `target/release/libsgc.a`, not
  `target/<triple>/release/libsgc.a`: cargo-deb treats a leading `target/release/`
  as target-relative and resolves it per architecture.
- `ldconfig` runs from `debian/runtime/postinst` (and `postrm`) to register the
  object in the linker cache. The dev package ships no maintainer scripts.

## How the split was checked

    link:   gcc tests/smoke/main.c -lsgc        -> smoke passes, DT_NEEDED libsgc.so.0
    split:  dpkg -r libsgc                      -> refused: libsgc-dev depends on libsgc
            dpkg -r --force-depends libsgc      -> the same binary dies with
                                                   "error while loading shared libraries:
                                                    libsgc.so.0"
    musl:   the musl archive linked by alpine's gcc/musl-dev -> smoke passes
    board:  the arm64 pair installed on the H618 board; ldconfig lists
            libsgc.so.0 (libc6,AArch64)
