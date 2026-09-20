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
rm -rf "$RES/share/applications" "$RES/share/dbus-1" "$RES/share/metainfo"

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

# Runtime data GLib/GTK look up by path, not relative to the binary.
cp -RL "$BREW/lib/gdk-pixbuf-2.0" "$RES/lib/"
mkdir -p "$RES/share/glib-2.0"
cp -RL "$BREW/share/glib-2.0/schemas" "$RES/share/glib-2.0/"
cp -RL "$BREW/share/icons" "$RES/share/"
glib-compile-schemas "$RES/share/glib-2.0/schemas"

# Rewrite every Mach-O's dependencies to @executable_path/../Frameworks.
# The -s paths resolve @rpath references; miss one and dylibbundler prompts for
# it on stdin and spins forever, so keep them complete rather than adding a timeout.
find "$RES/lib" -name '*.dylib' -exec printf -- '-x\n%s\n' {} + > /tmp/dino-bundle-args
# shellcheck disable=SC2046
dylibbundler -of -b -cd -d "$FW" -p '@executable_path/../Frameworks' \
    -s "$RES/lib" -s "$BREW/lib" \
    -x "$APP/Contents/MacOS/dino-bin" $(tr '\n' ' ' < /tmp/dino-bundle-args) >/dev/null
rm -f /tmp/dino-bundle-args
rm -f "$RES"/lib/*.dylib  # originals; dylibbundler copied them into Frameworks

# The check: nothing inside the bundle may still need a library from the build
# host. A CI runner has Homebrew installed, so launching proves nothing here --
# only the link table does. Skip each file's own install id (otool prints it
# first, and a copied plugin keeps the id it had in the Cellar).
leaked=$(find "$APP" -type f \( -name '*.dylib' -o -name 'dino-bin' \) -print0 \
    | xargs -0 -n1 otool -L \
    | awk -v brew="$BREW/" '/:$/ {n = 0; next} {n++}
                            n > 1 && index($1, brew) == 1 {print $1}' \
    | sort -u)
if [ -n "$leaked" ]; then
    echo "unbundled dependencies still referencing $BREW:" >&2
    echo "$leaked" >&2
    exit 1
fi

# Dino's icon fills its canvas edge to edge, which is right for a Linux icon
# theme but oversized next to other Dock icons. Inset it ~10% so it sits on the
# macOS grid at the same visual weight as its neighbours.
rsvg-convert --page-width 1024 --page-height 1024 -w 840 -h 840 --top 92 --left 92 \
    main/data/icons/scalable/apps/im.dino.Dino.svg -o /tmp/dino-1024.png
rm -rf /tmp/dino.iconset && mkdir /tmp/dino.iconset
for s in 16 32 64 128 256 512; do
    sips -z $s $s /tmp/dino-1024.png --out "/tmp/dino.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) /tmp/dino-1024.png --out "/tmp/dino.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns /tmp/dino.iconset -o "$RES/dino.icns"

VERSION=$("$APP/Contents/MacOS/dino-bin" --version 2>/dev/null | sed 's/^Dino //')
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
    <key>LSMinimumSystemVersion</key><string>12.0</string>
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
export XDG_DATA_DIRS="$res/share"
export GSETTINGS_SCHEMA_DIR="$res/share/glib-2.0/schemas"
export GDK_PIXBUF_MODULE_FILE="$res/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
export GST_PLUGIN_SYSTEM_PATH="$res/lib/gstreamer-1.0"
export GST_REGISTRY="${HOME}/Library/Caches/im.dino.Dino/gst-registry.bin"
mkdir -p "$(dirname "$GST_REGISTRY")"
exec "$(dirname "$0")/dino-bin" "$@"
LAUNCHER
chmod +x "$APP/Contents/MacOS/Dino"

# gdk-pixbuf's loader cache holds absolute Homebrew paths; regenerate against ours.
GDK_PIXBUF_MODULEDIR="$RES/lib/gdk-pixbuf-2.0/2.10.0/loaders" \
    gdk-pixbuf-query-loaders \
    > "$RES/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"

codesign --force --deep --sign - "$APP"

# The check: launch through the launcher, which is the path a user takes. Dino
# runs Gtk.init() before handling --version, so a missing runtime piece surfaces
# here rather than on someone else's Mac.
"$APP/Contents/MacOS/Dino" --version

echo "$APP  $(du -sh "$APP" | cut -f1)"
