#!/bin/sh
# Build a relocatable Dino.app from a Homebrew-based macOS build.
# Usage: build-aux/macos-bundle.sh [build-dir] [output.app]
set -eu

BUILD=${1:-build-macos}
APP=${2:-Dino.app}
BREW=$(brew --prefix)
RES="$APP/Contents/Resources"
FW="$APP/Contents/Frameworks"

# Homebrew packaging gaps, none of them Dino's: icu4c and gettext are keg-only;
# valac's built-in vapidir is its own Cellar prefix so it misses gee-0.8.vapi;
# libomemo-c.pc points -I at include/omemo though the vapi includes <omemo/*.h>
# and emits -lprotobuf-c without a -L for it.
export PKG_CONFIG_PATH="$(echo "$BREW"/opt/icu4c*/lib/pkgconfig | tr ' ' ':'):$BREW/opt/gettext/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export XDG_DATA_DIRS="$BREW/share:/usr/local/share:/usr/share"
export CPATH="$BREW/opt/libomemo-c/include"
export LIBRARY_PATH="$BREW/lib"

rm -rf "$APP"
# Install straight to the staging dir rather than via --destdir: meson bakes the
# prefix into each dylib's install_name, and dylibbundler can only rewrite those
# if the path it reads actually resolves on disk.
meson setup "$BUILD" --prefix="$PWD/$RES" --buildtype=release --wipe 2>/dev/null \
    || meson setup "$BUILD" --prefix="$PWD/$RES" --buildtype=release
meson install -C "$BUILD" >/dev/null

mkdir -p "$APP/Contents/MacOS" "$FW"
mv "$RES/bin/dino" "$APP/Contents/MacOS/dino-bin"
rmdir "$RES/bin"
rm -rf "$RES/share/applications" "$RES/share/dbus-1" "$RES/share/metainfo" \
    "$RES/include" "$RES/share/vala"

# GStreamer ships 277 plugins (~165M) but Dino only ever asks for these elements
# -- plugins/rtp/src/codec_util.vala plus the ElementFactory.make() calls around
# it. Resolving them through gst-inspect keeps us honest if GStreamer reshuffles
# which plugin file an element lives in, and fails loudly if one disappears.
GST_ELEMENTS="alawdec alawenc appsink appsrc audioconvert audiomixer audiorate
    audioresample audiotestsrc autoaudiosink autoaudiosrc avdec_g722 avdec_h264
    avenc_g722 avfvideosrc capsfilter decodebin dtlssrtpenc h264parse level
    mulawdec mulawenc opusdec opusenc osxaudiosink osxaudiosrc queue rtpbin
    rtpopusdepay rtpopuspay speexdec speexenc srtpenc tee typefind
    videoconvertscale videoflip videotestsrc volume vp8dec vp8enc vp9dec vp9enc
    vtdec x264enc"
mkdir -p "$RES/lib/gstreamer-1.0"
for e in $GST_ELEMENTS; do
    f=$(gst-inspect-1.0 "$e" 2>/dev/null | awk '/^  Filename/{print $2}')
    [ -n "$f" ] || { echo "no GStreamer element named $e" >&2; exit 1; }
    # -f because several elements share a plugin and Homebrew's copies are
    # read-only, so the second write to the same file would fail under set -e.
    cp -f "$f" "$RES/lib/gstreamer-1.0/"
done

# glib-networking ships GLib's TLS backend as a GIO module. Miss it and
# g_tls_backend_get_default() returns GDummyTlsBackend, so every XMPP
# connection fails before a socket is even opened.
mkdir -p "$RES/lib/gio/modules"
cp -f "$BREW"/lib/gio/modules/*.so "$RES/lib/gio/modules/"
# Must run before dylibbundler: gio-querymodules dlopens each module, which
# stops working once their deps point at @executable_path.
gio-querymodules "$RES/lib/gio/modules"
# A bundle that starts but has no TLS backend cannot reach any server, and
# --version will not notice. Assert the module actually registered.
grep -q gio-tls-backend "$RES/lib/gio/modules/giomodule.cache" \
    || { echo "bundled GIO modules provide no TLS backend" >&2; exit 1; }

# Runtime data GLib/GTK look up by path, not relative to the binary.
cp -RL "$BREW/lib/gdk-pixbuf-2.0" "$RES/lib/"
# Its cache must name every loader by absolute path, which only holds on the
# machine that wrote it, so ship a template and let the launcher fill in where
# the bundle actually lives. Query the Homebrew copies: the svg loader reaches
# librsvg through @rpath, which only resolves where Homebrew installed it.
cache="$RES/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
gdk-pixbuf-query-loaders \
    | sed "s|$BREW/lib/gdk-pixbuf-2.0|@RES@/lib/gdk-pixbuf-2.0|g" > "$cache"
# png and jpeg are built into gdk-pixbuf; svg is the module format that matters.
# Module lines are the ones naming a .so; the XPM loader's "/* XPM */" magic
# pattern also starts with a slash but is not a path.
if ! grep -q '"svg"' "$cache" || grep -q '^"/.*\.so"$' "$cache"; then
    echo "$cache lacks svg support or still holds absolute paths" >&2; exit 1
fi
mkdir -p "$RES/share/glib-2.0"
cp -RL "$BREW/share/glib-2.0/schemas" "$RES/share/glib-2.0/"
cp -RL "$BREW/share/icons" "$RES/share/"
glib-compile-schemas "$RES/share/glib-2.0/schemas"

# Rewrite every Mach-O's dependencies to @executable_path/../Frameworks.
# The -s paths resolve @rpath references; miss one and dylibbundler prompts for
# it on stdin and spins forever, so keep them complete rather than adding a timeout.
find "$RES/lib" \( -name '*.dylib' -o -name '*.so' \) -exec printf -- '-x\n%s\n' {} + > /tmp/dino-bundle-args
# shellcheck disable=SC2046
dylibbundler -of -b -cd -d "$FW" -p '@executable_path/../Frameworks' \
    -s "$RES/lib" -s "$BREW/lib" \
    -x "$APP/Contents/MacOS/dino-bin" $(tr '\n' ' ' < /tmp/dino-bundle-args) >/dev/null
rm -f /tmp/dino-bundle-args
rm -f "$RES"/lib/*.dylib  # originals; dylibbundler copied them into Frameworks

# dylibbundler adds its rpath even to a file that already carries it, and dyld
# on macOS 26 refuses to load any Mach-O with a duplicate LC_RPATH -- which
# silently broke the svg loader. Drop the extra copies and re-sign.
find "$APP" -type f \( -name '*.dylib' -o -name '*.so' -o -name dino-bin \) | while read -r f; do
    otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | sort | uniq -c \
        | awk '$1 > 1 {for (i = 1; i < $1; i++) print $2}' | while read -r r; do
        install_name_tool -delete_rpath "$r" "$f"
        codesign --force --sign - "$f"
    done
done

# The check: nothing inside the bundle may still need a library from the build
# host. A CI runner has Homebrew installed, so launching proves nothing here --
# only the link table does. Skip each file's own install id (otool prints it
# first, and a copied plugin keeps the id it had in the Cellar).
leaked=$(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' -o -name 'dino-bin' \) -print0 \
    | xargs -0 -n1 otool -L \
    | awk -v brew="$BREW/" '/:$/ {n = 0; next} {n++}
                            n > 1 && index($1, brew) == 1 {print $1}' \
    | sort -u)
if [ -n "$leaked" ]; then
    echo "unbundled dependencies still referencing $BREW:" >&2
    echo "$leaked" >&2
    exit 1
fi

# Homebrew builds GnuTLS with $BREW/etc/gnutls/cert.pem as its one and only
# trust source, so on a Mac without Homebrew it trusts nothing and every TLS
# handshake fails. Repoint it at the CA bundle macOS itself ships. The new path
# is NUL-padded to the old length so the C string stays intact. Re-sign at once:
# macOS kills any process that loads a library with a broken signature.
python3 - "$FW"/libgnutls.*.dylib "$BREW/etc/gnutls/cert.pem" /etc/ssl/cert.pem <<'PY'
import sys
lib, old, new = sys.argv[1], sys.argv[2].encode() + b"\0", sys.argv[3].encode()
data = open(lib, "rb").read()
assert data.count(old) == 1, f"expected {old!r} exactly once in {lib}"
open(lib, "wb").write(data.replace(old, new.ljust(len(old), b"\0")))
PY
codesign --force --sign - "$FW"/libgnutls.*.dylib

# Dino's icon fills its canvas edge to edge, which is right for a Linux icon
# theme but oversized next to other Dock icons. Inset it ~10% so it sits on the
# macOS grid at the same visual weight as its neighbours.
rsvg-convert --page-width 1024 --page-height 1024 -w 840 -h 840 --top 92 --left 92 \
    main/data/icons/scalable/apps/im.dino.Dino.svg -o /tmp/dino-1024.png
rm -rf /tmp/dino.iconset && mkdir /tmp/dino.iconset
for s in 16 32 128 256 512; do
    sips -z $s $s /tmp/dino-1024.png --out "/tmp/dino.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) /tmp/dino-1024.png --out "/tmp/dino.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns /tmp/dino.iconset -o "$RES/dino.icns"

# Bundle versions must be plain dotted numbers, so drop any ~git suffix.
VERSION=$("$APP/Contents/MacOS/dino-bin" --version 2>/dev/null | sed 's/^Dino //')
VERSION=${VERSION%%[!0-9.]*}
[ -n "$VERSION" ] || { echo "could not read a version from dino-bin" >&2; exit 1; }
# The real floor is whatever the newest bundled binary was built for, which is
# the macOS version Homebrew's bottles target on the build host.
MINOS=$(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' -o -name dino-bin \) \
    -exec otool -l {} + | awk '/minos/{print $2}' | sort -V | tail -1)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Dino</string>
    <key>CFBundleIconFile</key><string>dino.icns</string>
    <!-- Bundle id is what makes GLib pick GCocoaNotificationBackend. Without it
         GNotification silently no-ops and Dino shows no notifications at all. -->
    <key>CFBundleIdentifier</key><string>im.dino.Dino</string>
    <key>CFBundleName</key><string>Dino</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>${MINOS}</string>
    <key>NSCameraUsageDescription</key><string>Dino needs the camera for video calls.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Dino needs the microphone for calls.</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/Dino" <<'LAUNCHER'
#!/bin/sh
# Point GLib/GTK/GStreamer at the bundled copies, then hand off. The exec keeps
# the process image inside Contents/MacOS so +[NSBundle mainBundle] still
# resolves to this bundle, which is what enables Cocoa notifications.
res="$(cd "$(dirname "$0")/../Resources" && pwd)"
export DINO_PLUGIN_DIR="$res/lib/dino/plugins"
export DINO_LOCALE_DIR="$res/share/locale"
export GIO_MODULE_DIR="$res/lib/gio/modules"
export XDG_DATA_DIRS="$res/share"
export GSETTINGS_SCHEMA_DIR="$res/share/glib-2.0/schemas"
export GST_PLUGIN_SYSTEM_PATH="$res/lib/gstreamer-1.0"
cache="${HOME}/Library/Caches/im.dino.Dino"
mkdir -p "$cache"
export GST_REGISTRY="$cache/gst-registry.bin"
# gdk-pixbuf wants absolute loader paths, so fill in wherever the bundle lives
# right now. The inner sed escapes what is special in a sed replacement.
sed "s|@RES@|$(printf '%s' "$res" | sed 's/[&|\\]/\\&/g')|g" \
    "$res/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" > "$cache/loaders.cache"
export GDK_PIXBUF_MODULE_FILE="$cache/loaders.cache"
exec "$(dirname "$0")/dino-bin" "$@"
LAUNCHER
chmod +x "$APP/Contents/MacOS/Dino"

codesign --force --deep --sign - "$APP"

# The check: run a relocated copy the way it will run on someone else's Mac,
# with Homebrew and this build tree unreadable. Dino must start with every
# plugin loaded (it exits 0 even when one fails, so match the version line).
# bundle-check then covers what --version never loads, an svg and a verified
# TLS handshake, using the loader cache the launcher just wrote for this copy.
QA=$(mktemp -d)
ditto "$APP" "$QA/Dino.app"
Q="$QA/Dino.app/Contents/Resources"
cc build-aux/bundle-check.c -o "$QA/Dino.app/Contents/MacOS/bundle-check" \
    $(pkg-config --cflags gio-2.0 gdk-pixbuf-2.0) -L"$QA/Dino.app/Contents/Frameworks" \
    -lgdk_pixbuf-2.0.0 -lgio-2.0.0 -lgobject-2.0.0 -lglib-2.0.0
NOREAD="(version 1)(allow default)(deny file-read* (subpath \"$BREW\") (subpath \"$PWD\"))"
( cd "$QA" && HOME="$QA" sandbox-exec -p "$NOREAD" "$QA/Dino.app/Contents/MacOS/Dino" --version ) \
    | grep '^Dino '
( cd "$QA" && GIO_MODULE_DIR="$Q/lib/gio/modules" \
    GDK_PIXBUF_MODULE_FILE="$QA/Library/Caches/im.dino.Dino/loaders.cache" \
    sandbox-exec -p "$NOREAD" "$QA/Dino.app/Contents/MacOS/bundle-check" \
    "$Q/share/icons/hicolor/scalable/apps/im.dino.Dino.svg" )
rm -rf "$QA"

echo "$APP  $(du -sh "$APP" | cut -f1)"
