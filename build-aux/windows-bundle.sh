#!/bin/sh
# Build a self-contained Windows tree from an MSYS2 UCRT64 build.
# Usage: build-aux/windows-bundle.sh [build-dir] [output-dir]
set -eu

BUILD=${1:-build-windows}
OUT=${2:-dino-windows}
P=${MINGW_PREFIX:-/ucrt64}

# GtkBuilder looks UI classes up by name via g_type_from_name(). Without this
# dino.exe dies at startup with "Invalid object type 'DinoUiConversationSelector'".
export LDFLAGS="${LDFLAGS:-} -Wl,--export-all-symbols"

# Without MSYS2_ARG_CONV_EXCL the msys layer rewrites "/" into the msys root, so
# the prefix ends up as D:/a/_temp/msys64/ and every install path is wrong.
export MSYS2_ARG_CONV_EXCL="--prefix="

rm -rf "$OUT"
meson setup "$BUILD" --prefix=/ --buildtype=release --wrap-mode=nodownload --wipe 2>/dev/null \
    || meson setup "$BUILD" --prefix=/ --buildtype=release --wrap-mode=nodownload
meson install -C "$BUILD" --destdir "$PWD/$OUT"

# GLib relocates on Windows: with dino.exe in bin/ it finds share/ and lib/ from
# the module path, and SearchPathGenerator finds lib/dino/plugins the same way.
# So the install layout already works and only the DLLs need collecting.
# ponytail: whole GStreamer plugin dir. Subset it if download size matters.
# glib-networking ships GLib's TLS backend as a GIO module. Miss it and
# g_tls_backend_get_default() returns GDummyTlsBackend and no XMPP connection
# can be established at all.
cp -r "$P/lib/gio" "$OUT/lib/"
cp -r "$P/lib/gdk-pixbuf-2.0" "$OUT/lib/"
cp -r "$P/lib/gstreamer-1.0" "$OUT/lib/"
mkdir -p "$OUT/share/glib-2.0"
cp -r "$P/share/glib-2.0/schemas" "$OUT/share/glib-2.0/"
cp -r "$P/share/icons" "$OUT/share/"
glib-compile-schemas "$OUT/share/glib-2.0/schemas"
rm -rf "$OUT/share/applications" "$OUT/share/dbus-1" "$OUT/share/metainfo" \
    "$OUT/include" "$OUT/share/vala"
find "$OUT/lib" -name '*.dll.a' -delete

# ldd resolves the whole graph, so one pass over every module we ship is enough
# -- as long as each module can actually load. ldd quietly stops listing at the
# first DLL it cannot find, and the plugins link our own DLLs in bin/, so put
# bin/ on PATH. Without it libprotobuf-c and libassuan never got collected.
find "$OUT" -name '*.dll' > /tmp/dino-modules
echo "$OUT/bin/dino.exe" >> /tmp/dino-modules
# shellcheck disable=SC2046
PATH="$PWD/$OUT/bin:$PATH" ldd $(tr '\n' ' ' < /tmp/dino-modules) 2>/dev/null \
    | awk -v p="$P/" '$3 ~ "^"p {print $3}' | sort -u > /tmp/dino-dlls
xargs -a /tmp/dino-dlls -I{} cp {} "$OUT/bin/"
rm -f /tmp/dino-modules /tmp/dino-dlls

gio-querymodules "$OUT/lib/gio/modules"
# A bundle that starts fine but has no TLS backend cannot connect to
# anything, and --version will not notice. Assert the module registered.
grep -q gio-tls-backend "$OUT/lib/gio/modules/giomodule.cache" \
    || { echo "bundled GIO modules provide no TLS backend" >&2; exit 1; }

# Record loader paths relative to the install root, the directory above bin/:
# that is what gdk-pixbuf resolves relative paths against on Windows. Absolute
# ones would bake in the build directory.
( cd "$OUT" && GDK_PIXBUF_MODULEDIR=lib/gdk-pixbuf-2.0/2.10.0/loaders \
    gdk-pixbuf-query-loaders > lib/gdk-pixbuf-2.0/2.10.0/loaders.cache )
grep -q '"svg"' "$OUT/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" \
    || { echo "bundled gdk-pixbuf loaders have no svg support" >&2; exit 1; }

# The checks: run what we ship with nothing but bin/ on PATH. Dino must start
# with every plugin loaded -- it exits 0 even when one fails, so match the
# version line.
( cd "$OUT/bin" && PATH="$PWD" ./dino.exe --version ) | grep '^Dino '
# bundle-check covers what --version never loads: an svg and a verified TLS
# handshake. Run it from / so a path that only resolves from bin/ still fails.
cc build-aux/bundle-check.c -o "$OUT/bin/bundle-check.exe" $(pkg-config --cflags --libs gio-2.0 gdk-pixbuf-2.0)
B="$PWD/$OUT/bin"
( cd / && PATH="$B" "$B/bundle-check.exe" "$B/../share/icons/hicolor/scalable/apps/im.dino.Dino.svg" )
rm "$OUT/bin/bundle-check.exe"

du -sh "$OUT"
