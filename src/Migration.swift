// Pitpick used to be called Snelkeus. On the first start it takes over Snelkeus's settings
// (template, pins, locations, folders) and its rename logs, so nothing has to be set up again.
import Foundation

enum Migration {
    static func fromSnelkeus() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "migrated.snelkeus") {
            d.set(true, forKey: "migrated.snelkeus")
            if d.object(forKey: "pad.values") == nil, let old = UserDefaults(suiteName: "nl.wouter.snelkeus") {
                // dictionaryRepresentation also holds global settings: take only Snelkeus's own keys.
                for (k, v) in old.dictionaryRepresentation() where k.hasPrefix("pad.") || k == "doelmap" {
                    d.set(v, forKey: k)
                }
                if let frame = old.string(forKey: "NSWindow Frame Snelkeus.window") {
                    d.set(frame, forKey: "NSWindow Frame Pitpick.window")
                }
            }
        }
        // Rename logs, so Undo keeps working for renames done in Snelkeus. Moved, never deleted.
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let oldDir = base.appendingPathComponent("Snelkeus", isDirectory: true)
            let newDir = base.appendingPathComponent("Pitpick", isDirectory: true)
            if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
                try? fm.moveItem(at: oldDir, to: newDir)
            }
        }
    }
}
