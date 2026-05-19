import CGtk3
import Foundation

/// Decode raw image bytes into a `GdkPixbuf` sized to `targetSize × targetSize`.
///
/// The returned pixbuf is caller-owned (refcount 1). Pass it to
/// `gtk_image_new_from_pixbuf` (which takes its own ref) and then
/// `g_object_unref` our copy. If decoding fails — bad data, format the system
/// can't read, `gdk_pixbuf_loader_close` errors — this returns `nil` and the
/// caller falls back to a label-only menu item.
func decodePixbuf(data: Data, targetSize: Int) -> OpaquePointer? {
    guard let loader = gdk_pixbuf_loader_new() else { return nil }
    defer { g_object_unref(UnsafeMutableRawPointer(loader)) }

    let wrote = data.withUnsafeBytes { rawBuf -> Bool in
        guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return false }
        var err: UnsafeMutablePointer<GError>?
        let ok = gdk_pixbuf_loader_write(loader, base, gsize(rawBuf.count), &err)
        if err != nil { g_error_free(err) }
        return ok != 0
    }
    guard wrote else { return nil }

    var closeErr: UnsafeMutablePointer<GError>?
    let closed = gdk_pixbuf_loader_close(loader, &closeErr)
    if closeErr != nil { g_error_free(closeErr) }
    guard closed != 0 else { return nil }

    guard let pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
    // `gdk_pixbuf_loader_get_pixbuf` returns a borrowed reference. Take our
    // own ref so the pixbuf survives the loader's `g_object_unref` (via the
    // `defer` above), then drop it after we hand a scaled copy back.
    g_object_ref(UnsafeMutableRawPointer(pixbuf))
    defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }

    return gdk_pixbuf_scale_simple(
        pixbuf,
        Int32(targetSize),
        Int32(targetSize),
        GDK_INTERP_BILINEAR
    )
}
