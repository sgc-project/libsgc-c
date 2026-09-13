# Build & package recipes. Linkage convention (same as the daemon repo): musl
# targets are fully static, gnu targets are dynamically linked.
#
#   just                     build (release, host target)
#   just build-musl-x86_64   fully static x86_64 musl build
#   just build-musl-aarch64  fully static aarch64 musl build
#   just build-gnu-aarch64   dynamic aarch64 (gnu) build
#   just dist-gnu-aarch64    aarch64 build + libraries/headers into ./dist
#   just packages            all four installable .debs (headers + libsgc.a)
#   just ci                  the gate: fmt + clippy + tests + packages
#   just clean               remove ./target and ./dist

# What a build produces: the static archive the samples link, the shared object
# (needs a runtime package that is not built yet - see docs/packaging.md).
ARTIFACTS := "libsgc.a libsgc.so"

TARGET_GNU_AARCH64 := "aarch64-unknown-linux-gnu"
TARGET_MUSL_AMD64 := "x86_64-unknown-linux-musl"
TARGET_MUSL_AARCH64 := "aarch64-unknown-linux-musl"

STRIP_GNU_AARCH64 := "aarch64-linux-gnu-strip"

default: build

build:
    cargo build --release

# Fully static x86_64 musl build (crt-static comes from .cargo/config.toml).
build-musl-x86_64:
    cargo build --release --target {{TARGET_MUSL_AMD64}}

# Dynamically linked aarch64 (gnu) build - the board runs glibc.
build-gnu-aarch64:
    cargo build --release --target {{TARGET_GNU_AARCH64}}

# Fully static aarch64 musl build (musl.cc toolchain via ~/.cargo/bin).
build-musl-aarch64:
    cargo build --release --target {{TARGET_MUSL_AARCH64}}

# Copy one target's libraries plus the headers into ./dist, for hand use and for
# vendoring into a project that links the archive (sgc-demos does this).
#
# musl targets have no shared object: rustc drops the cdylib crate type for them
# ("unsupported crate type"), which is fine here - musl consumers link the
# archive statically.
dist-copy target strip:
    mkdir -p dist
    for f in {{ARTIFACTS}}; do [ -f target/{{target}}/release/$f ] || continue; cp target/{{target}}/release/$f dist/; {{strip}} dist/$f; done
    cp include/libsgc.h include/sgc.hpp dist/
    ls -1 dist/

dist-musl-x86_64: build-musl-x86_64
    just dist-copy {{TARGET_MUSL_AMD64}} {{STRIP_GNU_AARCH64}}

dist-gnu-aarch64: build-gnu-aarch64
    just dist-copy {{TARGET_GNU_AARCH64}} {{STRIP_GNU_AARCH64}}

dist-musl-aarch64: build-musl-aarch64
    just dist-copy {{TARGET_MUSL_AARCH64}} {{STRIP_GNU_AARCH64}}

clean:
    rm -rf target dist

# --- packages: installable .debs ------------------------------------------
#
# Two packages per glibc flavor, one per musl flavor:
#   libsgc       runtime - /usr/lib/libsgc.so, nothing else
#   libsgc-dev   the C/C++ headers and the static archive a client links
#
#   package-gnu-x86_64      amd64, headers + glibc archive      -> libsgc-dev
#   package-runtime-x86_64  amd64, the shared object            -> libsgc
#   package-musl-x86_64     amd64, headers + musl archive       -> libsgc-dev-musl
#   package-gnu-aarch64     arm64, headers + glibc archive      -> libsgc-dev
#   package-runtime-aarch64 arm64, the shared object            -> libsgc
#   package-musl-aarch64    arm64, headers + musl archive       -> libsgc-dev-musl
#
# There is no musl runtime package: rustc drops the cdylib crate type for musl
# targets, so no libsgc.so exists to ship there.
#
# libsgc-dev installs /usr/include/libsgc.h, /usr/include/sgc.hpp and
# /usr/lib/libsgc.a; libsgc installs /usr/lib/libsgc.so and runs ldconfig from
# its postinst (debian/runtime/). Each packages pairs with the daemon flavor of
# the same linkage, because the library is what a client links and the daemon is
# what it talks to: libsgc* -> simple-graphics-controller,
# libsgc-dev-musl -> simple-graphics-controller-musl.
#
# The glibc and musl flavors are alternatives, not companions: they install onto
# the same paths. Cross packaging cannot run dpkg-shlibdeps against the target's
# libraries, so each variant states its dependency explicitly (see Cargo.toml).
#
#   just packages                all six .debs into target/debian/
#   just package-runtime-aarch64 just one
#   just deb-info <file.deb>     what a package installs and depends on

# Each package's name (and therefore its output filename) differs, so nothing
# collides: cargo-deb derives the filename from name_version_arch whatever
# --variant says, and it rewrites target/debian when it packages.
package-gnu-x86_64: build
    cargo deb --no-build

package-runtime-x86_64: build
    cargo deb --no-build --variant runtime

package-musl-x86_64: build-musl-x86_64
    cargo deb --no-build --target {{TARGET_MUSL_AMD64}} --variant musl

package-gnu-aarch64: build-gnu-aarch64
    cargo deb --no-build --target {{TARGET_GNU_AARCH64}} --variant gnu-aarch64

package-runtime-aarch64: build-gnu-aarch64
    cargo deb --no-build --target {{TARGET_GNU_AARCH64}} --variant runtime-aarch64

package-musl-aarch64: build-musl-aarch64
    cargo deb --no-build --target {{TARGET_MUSL_AARCH64}} --variant musl

packages: package-gnu-x86_64 package-runtime-x86_64 package-musl-x86_64 package-gnu-aarch64 package-runtime-aarch64 package-musl-aarch64
    @echo "built:"
    @ls -1 target/debian/*.deb

# Show what a package installs and what it depends on.
deb-info file:
    dpkg-deb -c {{file}} | grep -E "usr/include|usr/lib" || true
    dpkg-deb -I {{file}} | grep -E "^ (Package|Version|Architecture|Depends|Conflicts)" || true

# --- the gate ---------------------------------------------------------------
ci: check test packages

check:
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings

test:
    cargo test
