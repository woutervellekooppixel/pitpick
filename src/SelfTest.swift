// Self test (--selftest), speed test (--bench) and screenshots (--snapshot, --snapshot-ingest).
// The self test only works on copies in a temporary folder; source files are never touched.
import AppKit

private func ms(_ v: Double) -> String { String(format: "%.1f ms", v) }

enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "OK    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    static func exif(_ path: String, _ tags: [String]) -> [String: Any] {
        let r = ExifTool.shared.run([["-j", "-n"] + tags.map { "-" + $0 } + [path]])
        guard let t = r.first?.text, let s = t.firstIndex(of: "["), let d = String(t[s...]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], let first = arr.first else { return [:] }
        return first
    }

    static func fileStamp(_ u: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        let size = (a?[.size] as? NSNumber)?.intValue ?? -1
        let date = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(date)"
    }

    /// Example job used by the tests: a real concert, with a neutral photographer name.
    static func examplePad() -> PadValues {
        var v = PadValues()
        v.values["event"] = "Frenna"
        v.values["location"] = "Ziggo Dome"
        v.values["city"] = "Amsterdam"
        v.values["creator"] = "Jane Doe"
        v.values["country"] = "Netherlands"
        v.values["countrycode"] = "NLD"
        v.values["usageterms"] = "No use without permission."
        v.values["webstatement"] = "example.com"
        v.date = "2025-11-29"
        // The rename, copy and ingest tests use a simple fixed name; the default is tested separately.
        v.fileTemplate = "{date}_{event}-{location}_{filename}"
        v.spacesToDashes = false
        return v
    }

    static func run(_ args: [String]) -> Int32 {
        guard let dir = args.first else { print("usage: --selftest <folder with CR3s> [lightroom.xmp] [preset.pitpick]"); return 2 }
        let fm = FileManager.default
        let src = URL(fileURLWithPath: dir)
        let lrXMP = args.count > 1 && args[1] != "-" ? URL(fileURLWithPath: args[1]) : nil
        let presetURL = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil
        print("exiftool: \(ExifTool.locate().map { ([$0.0] + $0.1).joined(separator: " ") } ?? "not found")")

        // 1. reading CR3
        let files = ((try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "cr3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        check(files.count >= 4, "test folder has CR3 files (\(files.count))")
        guard files.count >= 4 else { return 1 }
        var t0 = nowMs()
        let infos = files.map { CR3.read($0) }
        let perFile = (nowMs() - t0) / Double(files.count)
        check(infos.allSatisfy { $0 != nil }, "all CR3 files read, \(ms(perFile)) per file")
        check(infos.allSatisfy { ($0?.jpegLength ?? 0) > 1_000_000 && ($0?.prvwLength ?? 0) > 50_000 }, "full JPEG and PRVW found in every file")
        check(infos.allSatisfy { $0?.dateTimeOriginal != nil }, "capture time in every file")
        let portraitIndex = infos.firstIndex { $0?.orientation == 8 }
        check(portraitIndex != nil, "portrait photo recognised (orientation 8)")

        // 2. decoding
        let ref = SourceRef(id: 0, url: files[0], kind: .cr3, cr3: infos[0])
        t0 = nowMs(); let th = ImageDecoder.thumbnail(ref, maxPixels: 384); let tTh = nowMs() - t0
        check(th.map { max($0.image.width, $0.image.height) == 384 } ?? false, "thumbnail from PRVW: \(th?.image.width ?? 0)x\(th?.image.height ?? 0) in \(ms(tTh))")
        t0 = nowMs(); let sc = ImageDecoder.screen(ref); let tSc = nowMs() - t0
        check((sc?.image.width ?? 0) >= 4000 && (sc?.fullSize.width ?? 0) >= 8000, "screen image \(sc?.image.width ?? 0)x\(sc?.image.height ?? 0) of \(Int(sc?.fullSize.width ?? 0))x\(Int(sc?.fullSize.height ?? 0)) in \(ms(tSc))")
        t0 = nowMs(); let fu = ImageDecoder.full(ref); let tFu = nowMs() - t0
        check((fu?.image.width ?? 0) >= 8000, "100% image \(fu?.image.width ?? 0)x\(fu?.image.height ?? 0) in \(ms(tFu))")

        // 3. tokens and templates
        let v = examplePad()
        check(v.value("headline") == "Frenna at Ziggo Dome Amsterdam", "headline: \(v.value("headline"))")
        check(v.value("caption") == "Frenna, Ziggo Dome, Amsterdam, on 29-11-2025. Photo by Jane Doe", "caption: \(v.value("caption"))")
        check(v.list("keywords") == ["Frenna", "Ziggo Dome", "Amsterdam", "Jane Doe"], "keywords: \(v.list("keywords").joined(separator: "; "))")
        let shot = ExifDate.parse("2025:11:29 21:04:37", subSec: "48", offset: "+01:00") ?? Date()
        let camera = Photo(id: 99, url: URL(fileURLWithPath: "/tmp/_V1_3777.CR3"), kind: .cr3, cr3: nil, captureDate: shot, orientation: 1, companions: [])
        camera.captureZone = ExifDate.timeZone(from: "+01:00")
        check(v.fileName(photo: camera, seq: 1) == "2025-11-29_Frenna-Ziggo Dome__V1_3777", "fixed test name: \(v.fileName(photo: camera, seq: 1))")
        check(v.folderName == "2025-11-29_Frenna-Ziggo Dome", "folder name with spaces kept: \(v.folderName)")
        var d = examplePad()
        d.fileTemplate = PadValues().fileTemplate
        d.spacesToDashes = true
        check(d.fileName(photo: camera, seq: 1) == "2025-11-29_21-04-37_Frenna-Ziggo-Dome-Amsterdam_Jane-Doe", "default file name: \(d.fileName(photo: camera, seq: 1))")
        check(d.folderName == "2025-11-29_Frenna-Ziggo-Dome", "default folder name: \(d.folderName)")
        var dash = d
        dash.values["event"] = "Piano Man - Jeroen van den Boom"
        check(dash.folderName == "2025-11-29_Piano-Man-Jeroen-van-den-Boom-Ziggo-Dome", "' - ' becomes one dash: \(dash.folderName)")
        var noName = d
        noName.values["creator"] = ""
        check(noName.emptyReferences(in: [noName.fileTemplate]) == ["Photographer"], "a missing photographer name is caught")
        check(PadValues.tokens(in: "{Photographer}") == ["creator"], "{photographer} is the IPTC Creator field")
        let nyShot = ExifDate.parse("2025:11:30 00:12:05", subSec: nil, offset: "-05:00") ?? Date()
        let ny = Photo(id: 98, url: URL(fileURLWithPath: "/tmp/_V1_0001.CR3"), kind: .cr3, cr3: nil, captureDate: nyShot, orientation: 1, companions: [])
        ny.captureZone = ExifDate.timeZone(from: "-05:00")
        check(ny.shootDate == "2025-11-30" && ny.shootTime == "00-12-05", "shoot date and time follow the camera clock: \(ny.shootDate) \(ny.shootTime)")
        var empty = v
        empty.values["location"] = ""
        check(empty.emptyReferences(in: [empty.fileTemplate]) == ["Location"], "empty field in a name is caught")
        var old = v
        old.fileTemplate = "{datum}_{artiest}-{zaal}_{framenr}"
        check(old.fileName(photo: camera, seq: 1) == "2025-11-29_Frenna-Ziggo Dome_3777", "old Dutch tokens still work")

        // 3b. a personal preset reproduces the names and captions in the photographer's own archive
        if let pu = presetURL, let d = try? Data(contentsOf: pu), let preset = try? JSONDecoder().decode(Pad.Preset.self, from: d) {
            var w = preset.pad
            w.values["event"] = "Frenna"; w.values["location"] = "Ziggo Dome"; w.values["city"] = "Amsterdam"; w.date = "2025-11-29"
            check(w.value("headline") == "Frenna at Ziggo Dome Amsterdam", "preset headline equals the archive")
            check(w.value("caption") == "Frenna, Ziggo Dome, Amsterdam, on 29-11-2025. Photo by Wouter Vellekoop", "preset caption equals the archive")
            check(w.list("keywords").joined(separator: "; ") == "concert; live music; stage; lights; music photography; Frenna; Ziggo Dome; Amsterdam; Wouter Vellekoop", "preset keywords equal the archive")
            check(w.fileName(photo: camera, seq: 1) + ".cr3" == "2025-11-29_21-04-37_Frenna-Ziggo-Dome-Amsterdam_Wouter-Vellekoop.cr3", "preset file name: \(w.fileName(photo: camera, seq: 1))")
        }

        // working folder with copies under camera names
        let work = fm.temporaryDirectory.appendingPathComponent("pitpick-test-\(UUID().uuidString.prefix(6))")
        let card = work.appendingPathComponent("card/DCIM/100EOSR5")
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        var picks = [portraitIndex ?? 0]
        for i in files.indices where !picks.contains(i) && picks.count < 3 { picks.append(i) }
        var cameraFiles: [URL] = []
        for i in picks {
            let digits = String(files[i].deletingPathExtension().lastPathComponent.suffix(4))
            let target = card.appendingPathComponent("_V1_\(digits).CR3")
            if (try? fm.copyItem(at: files[i], to: target)) != nil { cameraFiles.append(target) }
        }
        check(cameraFiles.count == 3, "3 copies with camera names in \(card.path)")
        let stampsBefore = cameraFiles.map(fileStamp)

        // 4. reading like the app does (card folder with subfolders)
        t0 = nowMs()
        var photos = Scanner.load(Scanner.group(Scanner.collectFiles([work.appendingPathComponent("card")]))) { _ in }
        check(photos.count == 3, "card read: \(photos.count) photos in \(ms(nowMs() - t0))")
        check(photos.first?.orientation == 8, "sorted by capture time (James Arthur 24-11 first)")
        guard photos.count == 3 else { return 1 }
        if let dto = CR3.read(photos[0].url)?.dateTimeOriginal {
            let exifStamp = dto.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_")
            check(photos[0].shootDate + "_" + photos[0].shootTime == exifStamp, "shoot date and time equal the camera's EXIF (\(exifStamp))")
        }

        // 5. tag, stars, label into new XMPs
        let writer = StateWriter()
        writer.labelNames = { v.labelNames }
        photos[1].tagged = true
        photos[1].rating = 3
        photos[2].tagged = true
        photos[2].label = .purple
        writer.schedule(photos[1])
        writer.schedule(photos[2])
        t0 = nowMs()
        writer.flush(wait: true)
        let tWrite = nowMs() - t0
        let x1 = photos[1].url.deletingPathExtension().appendingPathExtension("xmp")
        check(fm.fileExists(atPath: x1.path), "XMP created next to the raw (\(ms(tWrite)) for 2 photos)")
        let e1 = exif(x1.path, ["XMP-xmp:Rating", "XMP-photomech:Tagged", "XMP-xmpMM:PreservedFileName"])
        check("\(e1["Rating"] ?? "")" == "3", "stars in XMP: \(e1["Rating"] ?? "-")")
        check("\(e1["Tagged"] ?? "")".lowercased() == "true" || "\(e1["Tagged"] ?? "")" == "1", "Photo Mechanic tag in XMP: \(e1["Tagged"] ?? "-")")
        check("\(e1["PreservedFileName"] ?? "")" == photos[1].url.lastPathComponent, "camera file name kept: \(e1["PreservedFileName"] ?? "-")")
        let e2 = exif(photos[2].metadataTarget.path, ["XMP-xmp:Label"])
        check("\(e2["Label"] ?? "")" == "Purple", "colour label in XMP: \(e2["Label"] ?? "-")")

        photos = Scanner.load(Scanner.group(Scanner.collectFiles([work.appendingPathComponent("card")]))) { _ in }
        check(photos.map { $0.tagged } == [false, true, true] && photos[1].rating == 3 && photos[2].label == .purple, "tags, stars and label come back on reopening")

        // 6. metadata from the open pad
        let cmds = photos.enumerated().map { i, p in ["-overwrite_original"] + v.metadataArgs(photo: p, seq: i + 1) + Metadata.stateArgs(p, labelNames: v.labelNames) + [p.metadataTarget.path] }
        t0 = nowMs()
        let res = ExifTool.shared.run(cmds)
        check(res.allSatisfy { $0.ok }, "metadata written to 3 photos in \(ms(nowMs() - t0)) \(res.filter { !$0.ok }.map { $0.text })")
        for p in photos where p.kind != .embedded { p.sidecar = p.metadataTarget }
        let e3 = exif(photos[0].metadataTarget.path, ["XMP-photoshop:Headline", "XMP-dc:Description", "XMP-dc:Subject", "XMP-photoshop:City",
                                                      "XMP-iptcCore:Location", "XMP-iptcExt:Event", "XMP-dc:Creator", "XMP-dc:Rights",
                                                      "XMP-photoshop:Credit", "XMP-photoshop:Country", "XMP-iptcCore:CountryCode",
                                                      "XMP-xmpRights:Marked", "XMP-xmpRights:WebStatement", "XMP-xmpRights:UsageTerms"])
        check("\(e3["Headline"] ?? "")" == "Frenna at Ziggo Dome Amsterdam", "Headline: \(e3["Headline"] ?? "-")")
        check("\(e3["Description"] ?? "")" == v.value("caption"), "Caption: \(e3["Description"] ?? "-")")
        let subj = (e3["Subject"] as? [Any])?.map { "\($0)" } ?? []
        check(subj == ["Frenna", "Ziggo Dome", "Amsterdam", "Jane Doe"], "keywords: \(subj.joined(separator: "; "))")
        check("\(e3["City"] ?? "")" == "Amsterdam" && "\(e3["Location"] ?? "")" == "Ziggo Dome" && "\(e3["Event"] ?? "")" == "Frenna", "city, location and event")
        check("\(e3["Rights"] ?? "")" == "© Jane Doe" && "\(e3["Credit"] ?? "")" == "© Jane Doe" && "\(e3["CountryCode"] ?? "")" == "NLD", "copyright, credit and country code")
        check("\(e3["WebStatement"] ?? "")" == "example.com" && "\(e3["UsageTerms"] ?? "")" == "No use without permission.", "web statement and usage terms")

        // 6b. the job fields come back from a photo's metadata (reopening an ingested folder)
        if let text = try? String(contentsOf: photos[0].metadataTarget, encoding: .utf8) {
            check(XMPState.values("Iptc4xmpExt:Event", in: text) == ["Frenna"] && XMPState.values("Iptc4xmpCore:Location", in: text) == ["Ziggo Dome"]
                  && XMPState.values("photoshop:City", in: text) == ["Amsterdam"], "event, location and city read back from the XMP")
        }

        // 7. an existing Lightroom XMP keeps all its develop settings
        if let lr = lrXMP, fm.fileExists(atPath: lr.path) {
            let copyLR = work.appendingPathComponent("lightroom.xmp")
            try? fm.copyItem(at: lr, to: copyLR)
            func fields() -> [String] {
                let t = ExifTool.shared.run([["-a", "-G1", "-s", "-s", "-XMP:all", copyLR.path]]).first?.text ?? ""
                return t.split(separator: "\n").map(String.init)
                    .filter { !$0.contains("XMPToolkit") && !$0.contains("] Rating:") && !$0.contains("] Label:") && !$0.contains("] Tagged:") }
                    .sorted()
            }
            let before = fields()
            _ = ExifTool.shared.run([["-overwrite_original"] + Metadata.stateArgs(tagged: false, rating: 2, label: .red, original: nil, labelNames: v.labelNames) + [copyLR.path]])
            let after = fields()
            let crs = before.filter { $0.hasPrefix("[XMP-crs]") }.count
            check(before.count > 100 && before == after, "Lightroom XMP: \(before.count) fields unchanged, \(crs) of them develop settings")
        }

        // 8. rename and undo
        let names = photos.map { $0.name }
        let plan = FileOps.planRename(photos) { p, n in v.fileName(photo: p, seq: n) }
        check(plan.items.count == 3, "rename plan for 3 photos")
        let r = FileOps.executeRename(plan.items)
        check(r.done == 3 && r.errors.isEmpty, "renamed: \(photos.map { $0.name }.joined(separator: ", "))")
        check(photos.allSatisfy { fm.fileExists(atPath: $0.url.path) && fm.fileExists(atPath: $0.metadataTarget.path) && $0.metadataTarget.lastPathComponent.hasPrefix("2025-11-29_Frenna") }, "XMP files moved along")
        if let log = r.log {
            let u = FileOps.undo(log)
            let back = names.allSatisfy { fm.fileExists(atPath: card.appendingPathComponent($0).path) }
            check(u.restored == 6 && back, "undone: \(u.restored) files back under the camera name")
        } else {
            check(false, "rename log")
        }

        // 8b. two frames in the same second get -2 with the default name (planned only)
        let burst = work.appendingPathComponent("burst")
        try? fm.createDirectory(at: burst, withIntermediateDirectories: true)
        try? fm.copyItem(at: files[picks[0]], to: burst.appendingPathComponent("_V1_2001.CR3"))
        try? fm.copyItem(at: files[picks[0]], to: burst.appendingPathComponent("_V1_2002.CR3"))
        let pair = Scanner.load(Scanner.group(Scanner.collectFiles([burst]))) { _ in }
        let burstPlan = FileOps.planRename(pair) { p, n in d.fileName(photo: p, seq: n) }
        let burstNames = burstPlan.items.map { $0.main.deletingPathExtension().lastPathComponent }.sorted()
        let stem = pair.first.map { d.fileName(photo: $0, seq: 1) } ?? "?"
        check(burstNames == [stem, stem + "-2"].sorted(), "same second: \(burstNames.joined(separator: ", "))")

        // 9. copy with new names and metadata, never overwrite
        photos = Scanner.load(Scanner.group(Scanner.collectFiles([work.appendingPathComponent("card")]))) { _ in }
        let tagged = photos.filter { $0.tagged }
        let dest = work.appendingPathComponent("archive/2025-11-29_Frenna-Ziggo Dome")
        let c1 = FileOps.copy(tagged, to: dest, name: { p, n in v.fileName(photo: p, seq: n) }, progress: { _ in }, cancelled: { false })
        check(c1.copied.count == 2 && c1.errors.isEmpty, "2 tagged photos copied")
        let copyCmds = c1.copied.map { ["-overwrite_original"] + v.metadataArgs(photo: $0.photo, seq: 1) + Metadata.stateArgs($0.photo, labelNames: v.labelNames) + [$0.metadataTarget.path] }
        check(ExifTool.shared.run(copyCmds).allSatisfy { $0.ok }, "metadata written into the copies")
        let destFiles = ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).sorted()
        check(destFiles.count == 4 && destFiles.allSatisfy { $0.hasPrefix("2025-11-29_Frenna-Ziggo Dome__V1_") }, "in the destination: \(destFiles.joined(separator: ", "))")
        let c2 = FileOps.copy(tagged, to: dest, name: { p, n in v.fileName(photo: p, seq: n) }, progress: { _ in }, cancelled: { false })
        check(c2.copied.isEmpty && c2.skipped.count == 2, "second time: nothing overwritten, \(c2.skipped.count) skipped")

        // 10. ingest from two cards, with a name clash between the bodies, then a resume
        let cardA = work.appendingPathComponent("cardA/DCIM/100EOSR5"), cardB = work.appendingPathComponent("cardB/DCIM/100EOSR5")
        try? fm.createDirectory(at: cardA, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cardB, withIntermediateDirectories: true)
        let others = files.indices.filter { !picks.contains($0) }
        if others.count >= 3 {
            try? fm.copyItem(at: files[others[0]], to: cardA.appendingPathComponent("_V1_1001.CR3"))
            try? fm.copyItem(at: files[others[1]], to: cardA.appendingPathComponent("_V1_1002.CR3"))
            try? fm.copyItem(at: files[others[2]], to: cardB.appendingPathComponent("_V1_1001.CR3"))   // same name, other body
            let cardStamps = [cardA, cardB].flatMap { d in ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).map(fileStamp) }
            let sources = Scanner.load(Scanner.group(Scanner.collectFiles([work.appendingPathComponent("cardA"), work.appendingPathComponent("cardB")]))) { _ in }
            check(sources.count == 3, "two cards read together: \(sources.count) photos")
            let raw = work.appendingPathComponent("jobs").appendingPathComponent(v.folderName).appendingPathComponent(v.rawFolder)
            var arrived: [Photo] = []
            t0 = nowMs()
            let ing = FileOps.ingest(sources, to: raw, name: { p, n in v.fileName(photo: p, seq: n) },
                                     metadata: { p in v.metadataArgs(photo: p, seq: 1) + Metadata.stateArgs(p, labelNames: v.labelNames) },
                                     cancelled: { false }, onPhoto: { arrived.append($0) })
            let inRaw = ((try? fm.contentsOfDirectory(atPath: raw.path)) ?? []).sorted()
            check(ing.copied == 3 && ing.suffixed == 1 && arrived.count == 3 && ing.errors.isEmpty,
                  "ingest: \(ing.copied) copied in \(ms(nowMs() - t0)), \(ing.suffixed) got -2, into \(raw.lastPathComponent)/")
            check(inRaw.count == 6 && inRaw.contains { $0.hasSuffix("_V1_1001-2.cr3") }, "raw folder: \(inRaw.joined(separator: ", "))")
            if let firstRaw = arrived.first {
                let e5 = exif(firstRaw.metadataTarget.path, ["XMP-photoshop:Headline", "XMP-xmpMM:PreservedFileName"])
                check("\(e5["Headline"] ?? "")" == "Frenna at Ziggo Dome Amsterdam" && "\(e5["PreservedFileName"] ?? "")".hasPrefix("_V1_"),
                      "ingested photo has its metadata and camera name (\(e5["PreservedFileName"] ?? "-"))")
            }
            var again: [Photo] = []
            let ing2 = FileOps.ingest(sources, to: raw, name: { p, n in v.fileName(photo: p, seq: n) },
                                      metadata: { _ in [] }, cancelled: { false }, onPhoto: { again.append($0) })
            let inRaw2 = ((try? fm.contentsOfDirectory(atPath: raw.path)) ?? []).count
            check(ing2.copied == 0 && ing2.alreadyThere == 3 && again.count == 3 && inRaw2 == 6, "ingest again: nothing copied twice, 3 already there")
            let cardStampsAfter = [cardA, cardB].flatMap { d in ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).map(fileStamp) }
            check(cardStamps == cardStampsAfter && cardStampsAfter.count == 3, "cards untouched by the ingest (no XMP written there)")
        }

        // 11. presets survive a round trip
        if let d = try? JSONEncoder().encode(Pad.Preset(pad: v, pinned: ["headline", "caption"], venues: ["Ziggo Dome": "Amsterdam"], readOnly: ["/Volumes/Archive"])),
           let back = try? JSONDecoder().decode(Pad.Preset.self, from: d) {
            check(back.pad == v && back.pinned == ["headline", "caption"] && back.venues?["Ziggo Dome"] == "Amsterdam" && back.readOnly == ["/Volumes/Archive"], "preset round trip")
        }

        // 12. the raws themselves were never touched
        check(cameraFiles.map(fileStamp) == stampsBefore, "CR3 files untouched (same size and date)")

        ExifTool.shared.stop()
        try? fm.removeItem(at: work)
        print(failures == 0 ? "\nAll good." : "\n\(failures) failure(s).")
        return failures == 0 ? 0 : 1
    }
}

enum Bench {
    static func run(_ args: [String]) -> Int32 {
        let urls = args.map { URL(fileURLWithPath: $0) }
        var t0 = nowMs()
        let photos = Scanner.load(Scanner.group(Scanner.collectFiles(urls))) { _ in }
        print("read: \(photos.count) photos in \(ms(nowMs() - t0))")
        guard photos.count > 10 else { return 1 }
        let pipe = ImagePipeline()

        let first = Array(photos.prefix(40))
        t0 = nowMs()
        pipe.requestThumbs(first.map { $0.ref })
        while first.contains(where: { pipe.thumb($0.id) == nil }) && nowMs() - t0 < 30000 { usleep(500) }
        print("first \(first.count) thumbnails ready in \(ms(nowMs() - t0))")

        for rate in [4.0, 8.0, 15.0, 25.0] {
            pipe.reset()
            var waits: [Double] = []
            let steps = min(photos.count - 1, 34)
            for i in 0..<steps {
                var refs: [SourceRef] = []
                for k in 0...7 where i + k < photos.count { refs.append(photos[i + k].ref) }
                if i > 0 { refs.append(photos[i - 1].ref) }
                let arrive = nowMs()
                pipe.want(refs)
                while pipe.screen(photos[i].id) == nil && nowMs() - arrive < 5000 { usleep(200) }
                let w = nowMs() - arrive
                waits.append(w)
                let dwell = 1000 / rate - w
                if dwell > 0 { usleep(UInt32(dwell * 1000)) }
            }
            let later = Array(waits.dropFirst())
            let sharp = later.filter { $0 < 5 }.count
            let sorted = later.sorted()
            print(String(format: "%4.0f photos/s: %d of %d instantly sharp, median %.1f ms, worst %.1f ms (first photo %.1f ms)",
                         rate, sharp, later.count, sorted[sorted.count / 2], sorted.last ?? 0, waits[0]))
        }
        return 0
    }
}

enum Snapshot {
    static var active = false
    static var log: [String] = []

    static func loadPreset(_ c: Controller, _ path: String) {
        if path != "-" { c.importPreset(from: URL(fileURLWithPath: path)) }
    }

    static func setJob(_ c: Controller) {
        c.pad.set("event", "Frenna")
        c.pad.set("location", "Ziggo Dome")
        c.pad.set("city", "Amsterdam")
    }

    /// --snapshot <folder> <output folder> [preset]
    static func start(_ c: Controller, args: [String]) {
        guard args.count >= 2 else { NSApp.terminate(nil); return }
        active = true
        let folder = URL(fileURLWithPath: args[0])
        let out = URL(fileURLWithPath: args[1])
        if args.count > 2 { loadPreset(c, args[2]) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        c.window.setContentSize(NSSize(width: 1460, height: 900))
        let t0 = nowMs()
        c.open([folder])
        waitUntil({ c.session.loading == nil && !c.session.photos.isEmpty }) {
            log.append("read: \(c.session.photos.count) photos in \(ms(nowMs() - t0))")
            setJob(c)
            after(2.0) {
                capture(c, out, "1-grid")
                state(c, "start")
                key(c, 17, "t")
                key(c, 124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
                key(c, 17, "t")
                key(c, 20, "3")
                key(c, 22, "6")
                state(c, "after t, right, t, 3, 6")
                after(0.8) {
                    capture(c, out, "2-tagged")
                    key(c, 36, "\r")
                    state(c, "after return")
                    after(0.8) {
                        capture(c, out, "3-loupe")
                        key(c, 49, " ")
                        state(c, "after space")
                        after(1.2) {
                            log.append("100%: full=\(c.pipeline.full(c.session.currentPhoto?.id ?? -1) != nil)")
                            capture(c, out, "4-100-percent")
                            key(c, 53, "\u{1b}")
                            if let i = c.session.visible.firstIndex(where: { $0.orientation == 8 }) { c.setCurrent(i) }
                            state(c, "after esc, portrait")
                            after(1.0) {
                                capture(c, out, "5-portrait")
                                key(c, 53, "\u{1b}")
                                key(c, 17, "t", [.command])
                                state(c, "after esc, cmd-T")
                                after(0.8) {
                                    capture(c, out, "6-tagged-only")
                                    finish(c, out)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// --snapshot-ingest <ingest folder> <output folder> <preset or -> <card> [card...]
    static func startIngest(_ c: Controller, args: [String]) {
        guard args.count >= 4 else { NSApp.terminate(nil); return }
        active = true
        let out = URL(fileURLWithPath: args[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        loadPreset(c, args[2])
        c.pad.ingestRoot = args[0]
        c.window.setContentSize(NSSize(width: 1460, height: 900))
        c.open(args[3...].map { URL(fileURLWithPath: $0) })
        waitUntil({ c.session.loading == nil && !c.session.photos.isEmpty }) {
            setJob(c)
            log.append("cards: \(c.session.photos.count) photos, destination \(c.ingestDestination?.path ?? "-")")
            after(1.5) {
                capture(c, out, "ingest-1-cards")
                let t0 = nowMs()
                c.ingest()
                after(0.6) {
                    capture(c, out, "ingest-2-busy")
                    waitUntil({ !c.session.ingesting }) {
                        log.append("ingest done in \(ms(nowMs() - t0)): \(c.session.photos.count) photos in view, message: \(c.session.message ?? "-")")
                        let files = (try? FileManager.default.contentsOfDirectory(atPath: c.ingestDestination?.path ?? "")) ?? []
                        log.append("raw folder: \(files.count) files, e.g. \(files.sorted().prefix(2).joined(separator: ", "))")
                        after(1.5) {
                            capture(c, out, "ingest-3-done")
                            finish(c, out)
                        }
                    }
                }
            }
        }
    }

    static func finish(_ c: Controller, _ out: URL) {
        c.writer.flush(wait: true)
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    static func key(_ c: Controller, _ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        NSApp.sendEvent(e)
    }

    static func state(_ c: Controller, _ step: String) {
        let p = c.session.currentPhoto
        let responder = c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        log.append("\(step): focus=\(responder) mode=\(c.session.mode) photo=\(c.session.currentIndex + 1)/\(c.session.visible.count) "
                   + "tagged=\(c.session.taggedCount) this: tag=\(p?.tagged ?? false) stars=\(p?.rating ?? 0) label=\(p?.label?.englishName ?? "-") "
                   + "zoom=\(c.main.loupe.zoomed) taggedOnly=\(c.session.onlyTagged)")
    }

    static func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    static func waitUntil(_ cond: @escaping () -> Bool, then f: @escaping () -> Void) {
        if cond() { f(); return }
        after(0.2) { waitUntil(cond, then: f) }
    }

    static func capture(_ c: Controller, _ out: URL, _ name: String) {
        guard let view = c.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        let scale = c.window.backingScaleFactor
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx)
        if let img = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
    }
}
