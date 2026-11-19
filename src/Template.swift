// The metadata pad: every IPTC field is open, and any value may use {tokens}
// such as {event}, {location}, {date} or the name of another field.
// Folder and file names are templates over the same tokens.
import Foundation

struct FieldDef {
    let key: String
    let label: String
    let tag: String        // exiftool tag to write
    let xmp: String        // XMP property to read back
    let list: Bool         // multiple values, separated by ;
    let initial: String
    let pinnedByDefault: Bool
}

enum Fields {
    // Generic defaults. Personal values (name, copyright, own templates) live in a preset (.snelkeus file).
    static let all: [FieldDef] = [
        FieldDef(key: "event", label: "Event", tag: "XMP-iptcExt:Event", xmp: "Iptc4xmpExt:Event", list: false, initial: "", pinnedByDefault: false),
        FieldDef(key: "location", label: "Location", tag: "XMP-iptcCore:Location", xmp: "Iptc4xmpCore:Location", list: false, initial: "", pinnedByDefault: false),
        FieldDef(key: "city", label: "City", tag: "XMP-photoshop:City", xmp: "photoshop:City", list: false, initial: "", pinnedByDefault: false),
        FieldDef(key: "personshown", label: "Person shown", tag: "XMP-iptcExt:PersonInImage", xmp: "Iptc4xmpExt:PersonInImage", list: true, initial: "", pinnedByDefault: false),
        FieldDef(key: "headline", label: "Headline", tag: "XMP-photoshop:Headline", xmp: "photoshop:Headline", list: false,
                 initial: "{event} at {location} {city}", pinnedByDefault: true),
        FieldDef(key: "caption", label: "Caption", tag: "XMP-dc:Description", xmp: "dc:description", list: false,
                 initial: "{event}, {location}, {city}, on {date-dmy}. Photo by {creator}", pinnedByDefault: true),
        FieldDef(key: "keywords", label: "Keywords", tag: "XMP-dc:Subject", xmp: "dc:subject", list: true,
                 initial: "{event}; {location}; {city}; {creator}", pinnedByDefault: true),
        FieldDef(key: "title", label: "Title", tag: "XMP-dc:Title", xmp: "dc:title", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "state", label: "State", tag: "XMP-photoshop:State", xmp: "photoshop:State", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "country", label: "Country", tag: "XMP-photoshop:Country", xmp: "photoshop:Country", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "countrycode", label: "Country code", tag: "XMP-iptcCore:CountryCode", xmp: "Iptc4xmpCore:CountryCode", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "creator", label: "Creator", tag: "XMP-dc:Creator", xmp: "dc:creator", list: true, initial: "", pinnedByDefault: true),
        FieldDef(key: "credit", label: "Credit line", tag: "XMP-photoshop:Credit", xmp: "photoshop:Credit", list: false, initial: "© {creator}", pinnedByDefault: true),
        FieldDef(key: "source", label: "Source", tag: "XMP-photoshop:Source", xmp: "photoshop:Source", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "copyright", label: "Copyright", tag: "XMP-dc:Rights", xmp: "dc:rights", list: false, initial: "© {creator}", pinnedByDefault: true),
        FieldDef(key: "usageterms", label: "Usage terms", tag: "XMP-xmpRights:UsageTerms", xmp: "xmpRights:UsageTerms", list: false,
                 initial: "", pinnedByDefault: true),
        FieldDef(key: "webstatement", label: "Web statement", tag: "XMP-xmpRights:WebStatement", xmp: "xmpRights:WebStatement", list: false,
                 initial: "", pinnedByDefault: true),
        FieldDef(key: "instructions", label: "Instructions", tag: "XMP-photoshop:Instructions", xmp: "photoshop:Instructions", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "captionwriter", label: "Caption writer", tag: "XMP-photoshop:CaptionWriter", xmp: "photoshop:CaptionWriter", list: false, initial: "", pinnedByDefault: true),
    ]

    static let byKey: [String: FieldDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// Old Dutch token names from version 1 keep working.
    static let aliases: [String: String] = [
        "artiest": "event", "artist": "event", "zaal": "location", "venue": "location", "stad": "city",
        "datum": "date", "datum-nl": "date-dmy", "framenr": "frame", "bestandsnaam": "filename",
        "volgnr": "seq", "jaar": "year", "description": "caption",
    ]

    static let dateTokens: Set<String> = ["date", "date-dmy", "year", "month", "day"]
    static let photoTokens: Set<String> = ["frame", "filename", "seq"]
}

/// Everything the pad holds, as a plain value: safe to hand to a background thread.
struct PadValues: Codable, Equatable {
    var values: [String: String] = Dictionary(uniqueKeysWithValues: Fields.all.map { ($0.key, $0.initial) })
    var date = ""
    var folderTemplate = "{date}_{event}-{location}"
    var fileTemplate = "{date}_{event}-{location}_{filename}"
    var rawFolder = "raw"
    var labels = "Red, Yellow, Green, Blue, Purple"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PadValues()
        var merged = d.values
        for (k, v) in try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:] where Fields.byKey[k] != nil { merged[k] = v }
        values = merged
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? d.date
        folderTemplate = try c.decodeIfPresent(String.self, forKey: .folderTemplate) ?? d.folderTemplate
        fileTemplate = try c.decodeIfPresent(String.self, forKey: .fileTemplate) ?? d.fileTemplate
        rawFolder = try c.decodeIfPresent(String.self, forKey: .rawFolder) ?? d.rawFolder
        labels = try c.decodeIfPresent(String.self, forKey: .labels) ?? d.labels
    }

    /// Lightroom label names in the order red, yellow, green, blue, purple.
    var labelNames: [String] {
        let parts = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let fallback = ["Red", "Yellow", "Green", "Blue", "Purple"]
        return (0..<5).map { i in i < parts.count && !parts[i].isEmpty ? parts[i] : fallback[i] }
    }

    static let tokenRegex = try! NSRegularExpression(pattern: #"\{([A-Za-z0-9\-]+)\}"#)

    static func tokens(in text: String) -> [String] {
        let ns = text as NSString
        return tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            let raw = ns.substring(with: $0.range(at: 1)).lowercased()
            return Fields.aliases[raw] ?? raw
        }
    }

    func resolve(_ text: String, photo: Photo? = nil, seq: Int = 1, depth: Int = 0) -> String {
        guard text.contains("{") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in Self.tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let raw = ns.substring(with: m.range(at: 1)).lowercased()
            let name = Fields.aliases[raw] ?? raw
            out += token(name, photo: photo, seq: seq, depth: depth) ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private func token(_ name: String, photo: Photo?, seq: Int, depth: Int) -> String? {
        let parts = date.split(separator: "-").map(String.init)
        switch name {
        case "date": return date
        case "date-dmy": return parts.count == 3 ? "\(parts[2])-\(parts[1])-\(parts[0])" : date
        case "year": return parts.first ?? ""
        case "month": return parts.count > 1 ? parts[1] : ""
        case "day": return parts.count > 2 ? parts[2] : ""
        case "frame": return photo?.frameNumber ?? "3777"
        case "filename": return photo?.originalBase ?? "IMG_3777"
        case "seq": return String(format: "%04d", seq)
        default:
            guard Fields.byKey[name] != nil, depth < 4 else { return nil }
            return resolve(values[name] ?? "", photo: photo, seq: seq, depth: depth + 1)
        }
    }

    func value(_ key: String, photo: Photo? = nil, seq: Int = 1) -> String {
        resolve(values[key] ?? "", photo: photo, seq: seq).trimmingCharacters(in: .whitespaces)
    }

    func list(_ key: String, photo: Photo? = nil, seq: Int = 1) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for part in value(key, photo: photo, seq: seq).split(separator: ";") {
            let w = part.trimmingCharacters(in: .whitespaces)
            if w.isEmpty || seen.contains(w.lowercased()) { continue }
            seen.insert(w.lowercased())
            out.append(w)
        }
        return out
    }

    func fileName(photo: Photo?, seq: Int) -> String { safeFileName(resolve(fileTemplate, photo: photo, seq: seq)) }
    var folderName: String { safeFileName(resolve(folderTemplate)) }

    /// exiftool arguments for every field that has a value. Empty fields are left alone.
    func metadataArgs(photo: Photo?, seq: Int) -> [String] {
        var a: [String] = []
        for f in Fields.all {
            if f.list {
                for item in list(f.key, photo: photo, seq: seq) { a.append("-\(f.tag)=\(item)") }
            } else {
                let v = value(f.key, photo: photo, seq: seq)
                if !v.isEmpty { a.append("-\(f.tag)=\(v)") }
            }
        }
        if !value("copyright").isEmpty { a.append("-XMP-xmpRights:Marked=True") }
        return a
    }

    /// Fields that a text refers to (directly or through other fields) but that are still empty.
    func emptyReferences(in texts: [String]) -> [String] {
        var seen = Set<String>()
        var missing: [String] = []
        func visit(_ text: String, _ depth: Int) {
            guard depth < 5 else { return }
            for n in Self.tokens(in: text) where !seen.contains(n) {
                seen.insert(n)
                if Fields.dateTokens.contains(n) {
                    if date.trimmingCharacters(in: .whitespaces).isEmpty && !missing.contains("Date") { missing.append("Date") }
                    continue
                }
                guard let f = Fields.byKey[n] else { continue }
                let raw = values[n] ?? ""
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { missing.append(f.label) } else { visit(raw, depth + 1) }
            }
        }
        texts.forEach { visit($0, 0) }
        return missing
    }

    /// The fields that will actually be written (non-empty), for the "empty reference" check.
    var writtenTexts: [String] { Fields.all.compactMap { f in (values[f.key] ?? "").isEmpty ? nil : values[f.key] } }
}

enum Metadata {
    /// exiftool arguments for tag, stars, colour label and the original camera file name.
    static func stateArgs(tagged: Bool, rating: Int, label: ColorLabel?, original: String?, labelNames: [String]) -> [String] {
        var a: [String] = []
        a.append(rating > 0 ? "-XMP-xmp:Rating=\(rating)" : "-XMP-xmp:Rating=")
        if let l = label { a.append("-XMP-xmp:Label=\(labelNames[l.rawValue - 1])") } else { a.append("-XMP-xmp:Label=") }
        a.append("-XMP-photomech:Tagged#=\(tagged ? "True" : "False")")
        if let o = original { a.append("-XMP-xmpMM:PreservedFileName=\(o)") }
        return a
    }

    static func stateArgs(_ p: Photo, labelNames: [String]) -> [String] {
        stateArgs(tagged: p.tagged, rating: p.rating, label: p.label,
                  original: p.hasStoredOriginal ? nil : p.originalFileName, labelNames: labelNames)
    }
}

/// The pad as the panel edits it. Saves itself; remembers which location belongs to which city.
final class Pad: ObservableObject {
    private let defaults = UserDefaults.standard
    private var cityIsAuto = false

    @Published var v: PadValues {
        didSet { if let d = try? JSONEncoder().encode(v) { defaults.set(d, forKey: "pad.values") } }
    }
    @Published var pinned: Set<String> { didSet { defaults.set(Array(pinned), forKey: "pad.pinned") } }
    @Published var ingestRoot: String { didSet { defaults.set(ingestRoot, forKey: "pad.ingestRoot") } }
    @Published var copyRoot: String { didSet { defaults.set(copyRoot, forKey: "pad.copyRoot") } }
    @Published var copyFolderOverride = ""
    /// Folders where Snelkeus never writes (for example an archive drive). View and copy only.
    @Published var readOnlyFolders: [String] { didSet { defaults.set(readOnlyFolders, forKey: "pad.readOnly") } }
    @Published private(set) var venues: [String: String]
    private var venueNames: [String: String]


    init() {
        if let d = defaults.data(forKey: "pad.values"), let p = try? JSONDecoder().decode(PadValues.self, from: d) { v = p } else { v = PadValues() }
        if let saved = defaults.array(forKey: "pad.pinned") as? [String] {
            pinned = Set(saved)
        } else {
            pinned = Set(Fields.all.filter { $0.pinnedByDefault }.map { $0.key })
        }
        ingestRoot = defaults.string(forKey: "pad.ingestRoot") ?? ""
        copyRoot = defaults.string(forKey: "pad.copyRoot") ?? defaults.string(forKey: "doelmap") ?? ""
        readOnlyFolders = defaults.stringArray(forKey: "pad.readOnly") ?? []
        var z: [String: String] = [:], n: [String: String] = [:]
        if let saved = defaults.dictionary(forKey: "pad.venues") as? [String: String] {
            for (loc, city) in saved { z[loc.lowercased()] = city; n[loc.lowercased()] = loc }
        }
        venues = z
        venueNames = n
    }

    var jobFields: [FieldDef] { Fields.all.filter { !pinned.contains($0.key) } }
    var templateFields: [FieldDef] { Fields.all.filter { pinned.contains($0.key) } }

    var knownVenues: [String] {
        venues.keys.compactMap { venueNames[$0] }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func get(_ key: String) -> String { v.values[key] ?? "" }

    func set(_ key: String, _ value: String) {
        v.values[key] = value
        if key == "city" { cityIsAuto = false }
        if key == "location", let c = venues[value.trimmingCharacters(in: .whitespaces).lowercased()], get("city").isEmpty || cityIsAuto {
            v.values["city"] = c
            cityIsAuto = true
        }
    }

    func togglePin(_ key: String) {
        if pinned.contains(key) { pinned.remove(key) } else { pinned.insert(key) }
    }

    /// Clears the per-job fields (the ones without a pin).
    func newJob() {
        var vals = v.values
        for f in jobFields { vals[f.key] = "" }
        v.values = vals
        copyFolderOverride = ""
        cityIsAuto = false
    }

    /// Opening a folder: a different folder than last time starts a new job, filled from the photos' own metadata.
    func open(folderKey: String, firstDay: String, xmp: () -> String?) {
        if defaults.string(forKey: "pad.job") != folderKey {
            newJob()
            if let text = xmp() { fill(from: text) }
            v.date = firstDay
            defaults.set(folderKey, forKey: "pad.job")
        } else if v.date.isEmpty {
            v.date = firstDay
        }
    }

    /// After an ingest the job continues in the new folder.
    func continueJob(in folderKey: String) { defaults.set(folderKey, forKey: "pad.job") }

    func fill(from text: String) {
        var vals = v.values
        for f in jobFields {
            let found = XMPState.values(f.xmp, in: text)
            if !found.isEmpty { vals[f.key] = found.joined(separator: "; ") }
        }
        v.values = vals
    }

    func rememberVenue() {
        let loc = v.value("location"), city = v.value("city")
        guard !loc.isEmpty, !city.isEmpty, !loc.contains("{"), !city.contains("{") else { return }
        venues[loc.lowercased()] = city
        venueNames[loc.lowercased()] = loc
        var saved = defaults.dictionary(forKey: "pad.venues") as? [String: String] ?? [:]
        saved[loc] = city
        defaults.set(saved, forKey: "pad.venues")
    }

    /// Puts the template fields and names back to the defaults; the job fields stay.
    func resetTemplate() {
        var fresh = PadValues()
        for f in jobFields { fresh.values[f.key] = v.values[f.key] ?? "" }
        fresh.date = v.date
        v = fresh
        pinned = Set(Fields.all.filter { $0.pinnedByDefault }.map { $0.key })
    }

    var copyFolderName: String {
        let o = copyFolderOverride.trimmingCharacters(in: .whitespaces)
        return safeFileName(o.isEmpty ? v.folderName : o)
    }

    // MARK: presets (.snelkeus files): the whole pad, the pins and the known locations

    struct Preset: Codable {
        var pad: PadValues
        var pinned: [String]
        var venues: [String: String]?
        var readOnly: [String]?
    }

    func isReadOnly(_ path: String) -> Bool {
        readOnlyFolders.contains { !$0.isEmpty && (path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")) }
    }

    func exportPreset() -> Data? {
        var saved: [String: String] = [:]
        for (k, city) in venues { saved[venueNames[k] ?? k] = city }
        var pad = v
        for f in jobFields { pad.values[f.key] = "" }
        pad.date = ""
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(Preset(pad: pad, pinned: Array(pinned).sorted(), venues: saved, readOnly: readOnlyFolders))
    }

    /// Loads a preset. The fields of the current job and its date stay as they are.
    func importPreset(_ data: Data) throws {
        let p = try JSONDecoder().decode(Preset.self, from: data)
        let newPinned = Set(p.pinned.filter { Fields.byKey[$0] != nil })
        var fresh = p.pad
        for f in Fields.all where !newPinned.contains(f.key) {
            let current = v.values[f.key] ?? ""
            if !current.isEmpty { fresh.values[f.key] = current }
        }
        fresh.date = v.date
        v = fresh
        pinned = newPinned
        if let ro = p.readOnly { readOnlyFolders = ro }
        if let list = p.venues {
            var saved = defaults.dictionary(forKey: "pad.venues") as? [String: String] ?? [:]
            for (loc, city) in list {
                venues[loc.lowercased()] = city
                venueNames[loc.lowercased()] = loc
                saved[loc] = city
            }
            defaults.set(saved, forKey: "pad.venues")
        }
    }
}
