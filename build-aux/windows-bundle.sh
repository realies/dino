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
rm -rf "$OUT/share/applications" "$OUT/share/dbus-1" "$OUT/share/metainfo"

# ldd resolves the whole graph, so one pass over every module we ship is enough.
find "$OUT" -name '*.dll' > /tmp/dino-modules
echo "$OUT/bin/dino.exe" >> /tmp/dino-modules
# shellcheck disable=SC2046
ldd $(tr '\n' ' ' < /tmp/dino-modules) 2>/dev/null \
    | awk -v p="$P/" '$3 ~ "^"p {print $3}' | sort -u > /tmp/dino-dlls
xargs -a /tmp/dino-dlls -I{} cp {} "$OUT/bin/"
rm -f /tmp/dino-modules /tmp/dino-dlls

gio-querymodules "$OUT/lib/gio/modules"
# A bundle that starts fine but has no TLS backend cannot connect to
# anything, and --version will not notice. Assert the module registered.
grep -q gio-tls-backend "$OUT/lib/gio/modules/giomodule.cache" \
    || { echo "bundled GIO modules provide no TLS backend" >&2; exit 1; }

# The cache records absolute build paths; rewrite it relative to bin/.
# Keep the recorded paths relative: absolute ones would bake in the build
# directory and break as soon as the zip is unpacked somewhere else.
( cd "$OUT/bin" && GDK_PIXBUF_MODULEDIR=../lib/gdk-pixbuf-2.0/2.10.0/loaders \
    gdk-pixbuf-query-loaders > ../lib/gdk-pixbuf-2.0/2.10.0/loaders.cache )
grep -q '"svg"' "$OUT/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" \
    || { echo "bundled gdk-pixbuf loaders have no svg support" >&2; exit 1; }

# The check: start the packaged exe with nothing from MSYS2 on PATH. It goes
# through Gtk.init() before handling --version, so a DLL we failed to collect
# shows up here rather than on a user's machine.
( cd "$OUT/bin" && PATH="$PWD" ./dino.exe --version )

du -sh "$OUT"
