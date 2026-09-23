/* Build-time check of what a bundled Dino only loads on demand, which a
 * --version smoke test never reaches: a gdk-pixbuf loader module (argv[1] is an
 * SVG) and GLib's TLS backend with a populated trust store. Used by
 * macos-bundle.sh and windows-bundle.sh; never shipped. */
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gio.h>

int main(int argc, char **argv)
{
    GError *error = NULL;
    GSocketClient *client = g_socket_client_new();

    if (argc != 2 || !gdk_pixbuf_new_from_file(argv[1], &error)) {
        g_printerr("SVG check failed: %s\n", error ? error->message : "usage: bundle-check FILE.svg");
        return 1;
    }
    g_socket_client_set_tls(client, TRUE);
    if (!g_socket_client_connect_to_host(client, "github.com", 443, NULL, &error)) {
        g_printerr("TLS check failed: %s\n", error->message);
        return 1;
    }
    g_print("SVG and TLS checks passed\n");
    return 0;
}
