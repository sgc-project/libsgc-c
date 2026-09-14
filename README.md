# libsgc-c

The C ABI for `libsgc`: the `<libsgc.h>` header, the `<sgc.hpp>` C++ wrapper,
and the `libsgc.a` static archive and `libsgc.so` shared library that export the
`sgc_*` symbols — built from the Rust core in
[libsgc-rs](https://github.com/lulkien/libsgc-rs).

Use it to put a C or C++ app on the
[**simple-graphics-controller**](https://github.com/lulkien/simple-graphics-controller)
daemon (`@sgc`): connect, take the DRM card you render on and the input devices
you consume, and drive the session — including the revoke / re-grant handshake
that lets another app take the screen away from yours and gives it back.

## The API in one screen

```c
#include <stdio.h>
#include <libsgc.h>

char err[128];
sgc_client *c = sgc_connect(err, sizeof(err));
if (!c) { fprintf(stderr, "no @sgc daemon: %s\n", err); return 1; }

sgc_resource *advertised = NULL;
size_t count = 0;
if (sgc_advertised(c, &advertised, &count) != 0) { /* see err */ }

/* Take the display first (input belongs to the client holding it), then the
   devices: SGC_RESOURCE_DRM / _FBDEV, then _MOUSE / _KEYBOARD / _TOUCH. */
for (size_t i = 0; i < count; i++) {
    if (advertised[i].kind == SGC_RESOURCE_DRM) {
        if (sgc_acquire(c, advertised[i], err, sizeof(err)) != 0) { /* denied */ }
    }
}

sgc_event ev;
int ret;
while ((ret = sgc_pump(c, -1, &ev, err, sizeof(err))) == 1) {
    if (ev.kind == SGC_EVENT_GRANTED) {
        /* ev.fd is yours: use it, close() the dups you took with sgc_fd() */
    }
    else {
        /* SGC_EVENT_REVOKED: stop drawing on the resource, close your dup */
    }
}
/* ret == -1: the session is over (every held resource was reported REVOKED
   first, one event per pump call) */

sgc_free(advertised);
sgc_release(c);
```

The header documents every function and its ownership rules; the short version is
that **each granted fd is the caller's to `close()`**, and the array from
`sgc_advertised` is freed with `sgc_free`. `sgc_pump` is the whole event loop:
`-1` blocks, `0` polls once, `> 0` waits that many milliseconds.

`tests/smoke/` compiles and exercises the entire surface from both C and C++
(`main.c`, `main.cc`), including the error channel and NULL-handle robustness.

## Build

    just build           # the library for the host
    just packages        # the .deb flavors (four targets, six packages)

The build needs the `libsgc-rs` checkout (the dependency) and, for cross builds,
the usual aarch64 toolchain — the recipes in the Justfile carry the flags.

## Link

Static, which is what the meson sample in
[libsgc](https://github.com/lulkien/simple-graphics-controller) does:

    gcc app.c -I include target/release/libsgc.a -lpthread -ldl -lm -o app

Shared: install the runtime package and link `-lsgc`. The library carries
`SONAME libsgc.so.0`, so a client built against the development package finds the
runtime package at run time.

## Packages

Every flavor is two `.deb`s, paired with the daemon flavor of the **same**
linkage: `libsgc-dev` (the headers and `libsgc.a`) and `libsgc` (the shared
object — glibc flavors only, since rustc emits no cdylib for musl). Install a
flavor family as one unit, dependents first in a single `dpkg -i` list
(`libsgc-dev`, then `libsgc`, then the daemon). Recipe names, install order, the
`-Wl,-soname` detail and why each package owns exactly its own file:
[docs/packaging.md](docs/packaging.md).

## License

Unlicense — public domain, see [LICENSE](LICENSE).
