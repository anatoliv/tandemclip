import AppKit
import Foundation

enum SecretPasteboard {
    static func copy(_ secret: String) {
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}
