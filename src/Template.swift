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

/// Code replacements, as in Photo Mechanic: a text file with on each line a code, a tab and its text, for example
/// `jb<tab>James Bay`. Type \jb\ in any field (or as the person in a photo) and the metadata says James Bay.
enum Codes {
    private static let lock = NSLock()
    private static var table: [String: String] = [:]

    /// Reads the file; the number of codes (0 when there is no file).
    @discardableResult
    static func load(_ path: String) -> Int {
        var t: [String: String] = [:]
        let text = path.isEmpty ? nil
            : (try? String(contentsOfFile: path, encoding: .utf8)) ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
        if let text = text {
            for line in text.split(whereSeparator: \.isNewline) {
                let cols = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if cols.count == 2, !cols[0].isEmpty { t[cols[0].lowercased()] = cols[1] }
            }
        }
        lock.lock(); table = t; lock.unlock()
        return t.count
    }

    static var count: Int { lock.lock(); defer { lock.unlock() }; return table.count }

    /// \\code\\ becomes its text; a code that is not in the file stays as it is.
    static func expand(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        lock.lock(); let t = table; lock.unlock()
        guard !t.isEmpty else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "\\") {
            out += rest[..<open]
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "\\") else { out += rest[open...]; return out }
            let code = String(rest[after..<close])
            if let r = t[code.lowercased()] { out += r } else { out += rest[open...close] }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

enum Fields {
    // Generic defaults. Personal values (name, copyright, own templates) live in a preset (.pitpick file).
    static let all: [FieldDef] = [
        FieldDef(key: "event", label: "Event", tag: "XMP-iptcExt:Event", xmp: "Iptc4xmpExt:Event", list: false, initial: "", pinnedByDefault: false),
        FieldDef(key: "location", label: "Location", tag: "XMP-iptcCore:Location", xmp: "Iptc4xmpCore:Location", list: false, initial: "", pinnedByDefault: false),
        FieldDef(key: "city", label: "City", tag: "XMP-photoshop:City", xmp: "photoshop:City", list: false, initial: "", pinnedByDefault: false),
        FieldDef(key: "personshown", label: "Person shown", tag: "XMP-iptcExt:PersonInImage", xmp: "Iptc4xmpExt:PersonInImage", list: true, initial: "", pinnedByDefault: false),
        FieldDef(key: "headline", label: "Headline", tag: "XMP-photoshop:Headline", xmp: "photoshop:Headline", list: false,
                 initial: "{event} at {location} {city}", pinnedByDefault: true),
        FieldDef(key: "caption", label: "Caption", tag: "XMP-dc:Description", xmp: "dc:description", list: false,
                 initial: "{event}, {location}, {city}, on {date-dmy}. Photo by {photographer}", pinnedByDefault: true),
        FieldDef(key: "keywords", label: "Keywords", tag: "XMP-dc:Subject", xmp: "dc:subject", list: true,
                 initial: "{event}; {location}; {city}; {photographer}", pinnedByDefault: true),
        FieldDef(key: "title", label: "Title", tag: "XMP-dc:Title", xmp: "dc:title", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "state", label: "State", tag: "XMP-photoshop:State", xmp: "photoshop:State", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "country", label: "Country", tag: "XMP-photoshop:Country", xmp: "photoshop:Country", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "countrycode", label: "Country code", tag: "XMP-iptcCore:CountryCode", xmp: "Iptc4xmpCore:CountryCode", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "creator", label: "Photographer", tag: "XMP-dc:Creator", xmp: "dc:creator", list: true, initial: "", pinnedByDefault: true),
        FieldDef(key: "credit", label: "Credit line", tag: "XMP-photoshop:Credit", xmp: "photoshop:Credit", list: false, initial: "© {photographer}", pinnedByDefault: true),
        FieldDef(key: "source", label: "Source", tag: "XMP-photoshop:Source", xmp: "photoshop:Source", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "copyright", label: "Copyright", tag: "XMP-dc:Rights", xmp: "dc:rights", list: false, initial: "© {photographer}", pinnedByDefault: true),
        FieldDef(key: "usageterms", label: "Usage terms", tag: "XMP-xmpRights:UsageTerms", xmp: "xmpRights:UsageTerms", list: false,
                 initial: "", pinnedByDefault: true),
        FieldDef(key: "webstatement", label: "Web statement", tag: "XMP-xmpRights:WebStatement", xmp: "xmpRights:WebStatement", list: false,
                 initial: "", pinnedByDefault: true),
        FieldDef(key: "instructions", label: "Instructions", tag: "XMP-photoshop:Instructions", xmp: "photoshop:Instructions", list: false, initial: "", pinnedByDefault: true),
        FieldDef(key: "captionwriter", label: "Caption writer", tag: "XMP-photoshop:CaptionWriter", xmp: "photoshop:CaptionWriter", list: false, initial: "", pinnedByDefault: true),
    ]

    static let byKey: [String: FieldDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// Other names for the same tokens: {photographer} is the IPTC Creator field, and the old Dutch names from version 1 keep working.
    static let aliases: [String: String] = [
        "photographer": "creator", "shoot-date": "shootdate",
        "artiest": "event", "artist": "event", "zaal": "location", "venue": "location", "stad": "city",
        "datum": "date", "datum-nl": "date-dmy", "framenr": "frame", "bestandsnaam": "filename",
        "volgnr": "seq", "jaar": "year", "description": "caption",
    ]

    static let dateTokens: Set<String> = ["date", "date-dmy", "year", "month", "day"]
    static let photoTokens: Set<String> = ["frame", "filename", "seq", "shootdate", "time"]
}

/// Everything the pad holds, as a plain value: safe to hand to a background thread.
struct PadValues: Codable, Equatable {
    var values: [String: String] = Dictionary(uniqueKeysWithValues: Fields.all.map { ($0.key, $0.initial) })
    var date = ""
    var folderTemplate = "{date}_{event}-{location}"
    /// The camera's frame number at the end keeps frames shot in the same second in shooting order.
    var fileTemplate = PadValues.defaultFileTemplate
    static let defaultFileTemplate = "{shootdate}_{time}_{event}-{location}-{city}_{photographer}_{frame}"
    /// The default of versions 1.2-1.3.2, without the frame number: moved to the new default when found.
    static let oldDefaultFileTemplate = "{shootdate}_{time}_{event}-{location}-{city}_{photographer}"
    var rawFolder = "raw"
    var labels = "Red, Yellow, Green, Blue, Purple"
    /// Spaces in folder and file names become dashes: "Ziggo Dome" -> "Ziggo-Dome".
    var spacesToDashes = true

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
        // 1.2-1.3.2 default without the frame number: frames in the same second did not sort (1.4)
        if fileTemplate == PadValues.oldDefaultFileTemplate { fileTemplate = PadValues.defaultFileTemplate }
        rawFolder = try c.decodeIfPresent(String.self, forKey: .rawFolder) ?? d.rawFolder
        labels = try c.decodeIfPresent(String.self, forKey: .labels) ?? d.labels
        spacesToDashes = try c.decodeIfPresent(Bool.self, forKey: .spacesToDashes) ?? d.spacesToDashes
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

    /// The job date as yyyy-MM-dd, also when typed as 19-11-2026, 19/11/2026, 19.11.2026 or 20261119.
    /// nil when it is empty or not clear.
    var isoDate: String? {
        let d = date.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return nil }
        let parts = d.split(whereSeparator: { "-/. ".contains($0) }).map(String.init)
        var y = 0, m = 0, day = 0
        if parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) {
            if parts[0].count == 4 { y = a; m = b; day = c } else if parts[2].count == 4 { y = c; m = b; day = a } else { return nil }
        } else if parts.count == 1, d.count == 8, let v = Int(d) {
            y = v / 10000; m = (v / 100) % 100; day = v % 100
        } else {
            return nil
        }
        guard (1900...2200).contains(y), (1...12).contains(m), (1...31).contains(day) else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, day)
    }

    /// A date that is filled in but cannot be read, for a clear message instead of a wrong name.
    var dateProblem: String? {
        let d = date.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, isoDate == nil else { return nil }
        return "The date \"\(d)\" is not clear: write it as 2026-11-19."
    }

    private func token(_ name: String, photo: Photo?, seq: Int, depth: Int) -> String? {
        let iso = isoDate ?? date
        let parts = iso.split(separator: "-").map(String.init)
        switch name {
        case "date": return iso
        case "date-dmy": return parts.count == 3 ? "\(parts[2])-\(parts[1])-\(parts[0])" : iso
        case "year": return parts.first ?? ""
        case "month": return parts.count > 1 ? parts[1] : ""
        case "day": return parts.count > 2 ? parts[2] : ""
        case "frame":
            // a camera name without digits at the end: the whole original name, so the name stays unique
            guard let p = photo else { return "3777" }
            return p.frameNumber.isEmpty ? p.originalBase : p.frameNumber
        case "filename": return photo?.originalBase ?? "IMG_3777"
        case "seq": return String(format: "%04d", seq)
        case "shootdate": return photo?.shootDate ?? (iso.isEmpty ? "2026-11-19" : iso)
        case "time": return photo?.shootTime ?? "21-04-37"
        default:
            guard Fields.byKey[name] != nil, depth < 4 else { return nil }
            return resolve(raw(name, photo: photo), photo: photo, seq: seq, depth: depth + 1)
        }
    }

    /// A field as typed; Person shown can differ per photo.
    private func raw(_ key: String, photo: Photo?) -> String {
        if key == "personshown", let ppl = photo?.people { return ppl.joined(separator: "; ") }
        return values[key] ?? ""
    }

    func value(_ key: String, photo: Photo? = nil, seq: Int = 1) -> String {
        Codes.expand(resolve(raw(key, photo: photo), photo: photo, seq: seq)).trimmingCharacters(in: .whitespaces)
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

    func fileName(photo: Photo?, seq: Int) -> String { tidy(Codes.expand(resolve(fileTemplate, photo: photo, seq: seq))) }
    var folderName: String { tidy(Codes.expand(resolve(folderTemplate))) }

    /// A safe name; with the option on, spaces become dashes ("Piano Man - Jeroen" -> "Piano-Man-Jeroen").
    func tidy(_ s: String) -> String {
        let clean = safeFileName(s)
        guard spacesToDashes else { return clean }
        // "AC/DC: Live?" becomes AC-DC-Live, not AC-DC-Live--
        return safeFileName(clean.replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression))
    }

    /// Tokens that are neither a field nor a date or photo token (a typo such as {evnt}), as written.
    func unknownTokens(in texts: [String]) -> [String] {
        var out: [String] = []
        for t in texts {
            let ns = t as NSString
            for m in Self.tokenRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range(at: 1)).lowercased()
                let name = Fields.aliases[raw] ?? raw
                if Fields.byKey[name] != nil || Fields.dateTokens.contains(name) || Fields.photoTokens.contains(name) { continue }
                let shown = ns.substring(with: m.range)
                if !out.contains(shown) { out.append(shown) }
            }
        }
        return out
    }

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
        if let p = photo, p.clockOffset != 0 {
            // the camera's clock was corrected: Lightroom and Photo Mechanic read the capture time from the XMP
            let when = ExifDate.xmpString(p.captureDate, zone: p.captureZone)
            a.append("-XMP-exif:DateTimeOriginal=\(when)")
            a.append("-XMP-photoshop:DateCreated=\(when)")
        }
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

    /// Who is in this one photo, when set for it (the job's Person shown otherwise comes with the other fields).
    static func peopleArgs(_ p: Photo) -> [String] {
        guard let ppl = p.people else { return [] }
        let names = ppl.map { Codes.expand($0) }.filter { !$0.isEmpty }
        return names.isEmpty ? ["-XMP-iptcExt:PersonInImage="] : names.map { "-XMP-iptcExt:PersonInImage=\($0)" }
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
    /// Incremental ingest: photos ingested before are skipped (on by default).
    @Published var skipIngested: Bool { didSet { defaults.set(skipIngested, forKey: "pad.skipIngested") } }
    /// Ingest: tagged, rated and labelled photos (also protected or rated in the camera) are copied first.
    @Published var priorityFirst: Bool { didSet { defaults.set(priorityFirst, forKey: "pad.priorityFirst") } }
    /// Ingest: a second copy goes here (<job folder>/<raw folder>, the same names). Empty = none.
    @Published var backupRoot: String { didSet { defaults.set(backupRoot, forKey: "pad.backupRoot") } }
    /// Ingest: every copy is read back from its disk and checked against the card (SHA-256).
    @Published var verifyCopies: Bool { didSet { defaults.set(verifyCopies, forKey: "pad.verifyCopies") } }
    /// Ingest: eject the cards when everything is copied without problems.
    @Published var ejectCards: Bool { didSet { defaults.set(ejectCards, forKey: "pad.ejectCards") } }
    /// A photo protected in the camera counts as tagged when you open the card.
    @Published var protectedIsTagged: Bool {
        didSet { defaults.set(protectedIsTagged, forKey: "pad.protectedIsTagged"); Scanner.lockedIsTagged = protectedIsTagged }
    }
    /// Copy selection as raw files (0) or as the camera's JPEG (1).
    @Published var copyFormat: Int { didSet { defaults.set(copyFormat, forKey: "pad.copyFormat") } }
    /// JPEG long edge in pixels (0 = full size, as the camera made it).
    @Published var jpegLongEdge: Int { didSet { defaults.set(jpegLongEdge, forKey: "pad.jpegLongEdge") } }
    /// Code replacements file (tab-separated: code, text). Empty = none.
    @Published var codeFile: String { didSet { defaults.set(codeFile, forKey: "pad.codeFile"); Codes.load(codeFile) } }
    /// After a tag, stars or a label: the next photo (or keep Caps Lock on, as in Lightroom).
    @Published var autoAdvance: Bool { didSet { defaults.set(autoAdvance, forKey: "view.autoAdvance") } }
    /// Clock corrections per camera body (serial number), in seconds. Kept: a body keeps drifting the same way.
    @Published var clockOffsets: [String: Double] { didSet { defaults.set(clockOffsets, forKey: "clock.offsets") } }
    /// T also sets this colour label (1-5, 0 = none), for Lightroom, which does not read the tag.
    @Published var tagLabel: Int { didSet { defaults.set(tagLabel, forKey: "pad.tagLabel") } }
    @Published var copyFolderOverride = ""
    /// Folders where Pitpick never writes (for example an archive drive). View and copy only.
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
        skipIngested = defaults.object(forKey: "pad.skipIngested") as? Bool ?? true
        priorityFirst = defaults.object(forKey: "pad.priorityFirst") as? Bool ?? true
        ejectCards = defaults.object(forKey: "pad.ejectCards") as? Bool ?? false
        backupRoot = defaults.string(forKey: "pad.backupRoot") ?? ""
        verifyCopies = defaults.bool(forKey: "pad.verifyCopies")
        protectedIsTagged = defaults.object(forKey: "pad.protectedIsTagged") as? Bool ?? true
        tagLabel = defaults.integer(forKey: "pad.tagLabel")
        autoAdvance = defaults.bool(forKey: "view.autoAdvance")
        copyFormat = defaults.integer(forKey: "pad.copyFormat")
        codeFile = defaults.string(forKey: "pad.codeFile") ?? ""
        jpegLongEdge = defaults.integer(forKey: "pad.jpegLongEdge")
        clockOffsets = defaults.dictionary(forKey: "clock.offsets") as? [String: Double] ?? [:]
        var z: [String: String] = [:], n: [String: String] = [:]
        if let saved = defaults.dictionary(forKey: "pad.venues") as? [String: String] {
            for (loc, city) in saved { z[loc.lowercased()] = city; n[loc.lowercased()] = loc }
        }
        venues = z
        venueNames = n
        Scanner.lockedIsTagged = protectedIsTagged
        Codes.load(codeFile)
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

    /// 19-11-2026 typed in the date field becomes 2026-11-19.
    func normalizeDate() {
        if let iso = v.isoDate, iso != v.date { v.date = iso }
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
    /// Returns true when this started a new job.
    @discardableResult
    func open(folderKey: String, firstDay: String, xmp: () -> String?) -> Bool {
        if defaults.string(forKey: "pad.job") != folderKey {
            newJob()
            if let text = xmp() { fill(from: text) }
            v.date = firstDay
            defaults.set(folderKey, forKey: "pad.job")
            return true
        } else if v.date.isEmpty {
            v.date = firstDay
        }
        return false
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

    // MARK: presets (.pitpick files; old .snelkeus files load too): the whole pad, the pins and the known locations

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
