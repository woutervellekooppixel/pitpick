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

    /// A check that cannot run with these test files (not a failure).
    static func skip(_ what: String) { print("SKIP  " + what) }

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
        // "-" or an empty string: no Lightroom XMP to test with
        let lrXMP = args.count > 1 && !args[1].isEmpty && args[1] != "-" ? URL(fileURLWithPath: args[1]) : nil
        let presetURL = args.count > 2 && !args[2].isEmpty && args[2] != "-" ? URL(fileURLWithPath: args[2]) : nil
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
        let portraitIndex = infos.firstIndex { Orientation.swapsAxes($0?.orientation ?? 1) }
        if let i = portraitIndex {
            check(true, "portrait photo recognised (orientation \(infos[i]?.orientation ?? 0))")
        } else {
            skip("no portrait photo in the test folder, so the rotation checks are left out")
        }

        // 2. decoding
        let ref = SourceRef(id: 0, url: files[0], kind: .cr3, cr3: infos[0])
        t0 = nowMs(); let th = ImageDecoder.thumbnail(ref, maxPixels: 384); let tTh = nowMs() - t0
        check(th.map { max($0.image.width, $0.image.height) == 384 } ?? false, "thumbnail from PRVW: \(th?.image.width ?? 0)x\(th?.image.height ?? 0) in \(ms(tTh))")
        t0 = nowMs(); let sc = ImageDecoder.screen(ref); let tSc = nowMs() - t0
        check((sc?.image.width ?? 0) >= 4000 && (sc?.fullSize.width ?? 0) >= 8000, "screen image \(sc?.image.width ?? 0)x\(sc?.image.height ?? 0) of \(Int(sc?.fullSize.width ?? 0))x\(Int(sc?.fullSize.height ?? 0)) in \(ms(tSc))")
        t0 = nowMs(); let fu = ImageDecoder.full(ref); let tFu = nowMs() - t0
        check((fu?.image.width ?? 0) >= 8000, "100% image \(fu?.image.width ?? 0)x\(fu?.image.height ?? 0) in \(ms(tFu))")

        // 2b. libjpeg-turbo (Apple Silicon) gives the same picture as the hardware decoder
        if let t = TurboDecoder() {
            t0 = nowMs(); let ts = ImageDecoder.screen(ref, turbo: t); let tTs = nowMs() - t0
            t0 = nowMs(); let tf = ImageDecoder.full(ref, turbo: t); let tTf = nowMs() - t0
            let diff = (ts?.image).flatMap { a in (sc?.image).map { b in meanDifference(a, b) } } ?? 999
            // the two decoders round differently (about 1.4/255 at full size, no colour shift); at half size the
            // software one scales in the DCT and differs about 2/255, which is not visible side by side
            check(ts?.image.width == sc?.image.width && ts?.image.height == sc?.image.height && ts?.fullSize == sc?.fullSize && diff < 3,
                  String(format: "software screen image %dx%d in %@, differs %.2f/255 from the hardware one", ts?.image.width ?? 0, ts?.image.height ?? 0, ms(tTs), diff))
            check(tf?.image.width == fu?.image.width && tf?.isFull == true, "software 100% image \(tf?.image.width ?? 0)x\(tf?.image.height ?? 0) in \(ms(tTf))")
            let pv = ImageDecoder.preview(ref)
            check((pv?.image.width ?? 0) >= 1600, "loupe stand-in from the PRVW: \(pv?.image.width ?? 0)x\(pv?.image.height ?? 0)")
        } else {
            skip("libjpeg-turbo is not in this build (Intel): the hardware decoder does everything")
        }

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
        check(d.fileName(photo: camera, seq: 1) == "2025-11-29_21-04-37_Frenna-Ziggo-Dome-Amsterdam_Jane-Doe_3777", "default file name ends with the frame number: \(d.fileName(photo: camera, seq: 1))")
        var oldDefault = d
        oldDefault.fileTemplate = PadValues.oldDefaultFileTemplate
        if let data = try? JSONEncoder().encode(oldDefault), let back = try? JSONDecoder().decode(PadValues.self, from: data) {
            check(back.fileTemplate == PadValues.defaultFileTemplate, "the 1.2-1.3 default name moves to the one with the frame number")
        }
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

        // 3a. template checks: typos, dates typed by hand, hidden and too long names
        check(v.unknownTokens(in: ["{shootdate}_{evnt}-{location}_{Photographer}"]) == ["{evnt}"], "unknown token {evnt} is caught, known ones pass")
        var typed = v
        typed.date = "29-11-2025"
        check(typed.isoDate == "2025-11-29" && typed.value("caption").contains("29-11-2025") && typed.folderName.hasPrefix("2025-11-29_"),
              "date typed as 29-11-2025 is read as 2025-11-29")
        typed.date = "29-13-2025"
        check(typed.dateProblem != nil, "an impossible date is caught")
        check(safeFileName(".Hidden show") == "Hidden show", "a name never starts with a dot (hidden in Finder)")
        check(safeFileName(String(repeating: "Symphonic Orchestra ", count: 20)).utf8.count <= 200, "names are cut at 200 bytes, so they always fit")
        var acdc = d
        acdc.values["event"] = "AC/DC: Live?"
        check(!acdc.fileName(photo: camera, seq: 1).contains("--"), "no double dashes: \(acdc.fileName(photo: camera, seq: 1))")

        // 3b. a personal preset reproduces the names and captions in the photographer's own archive
        if let pu = presetURL, let d = try? Data(contentsOf: pu), let preset = try? JSONDecoder().decode(Pad.Preset.self, from: d) {
            var w = preset.pad
            w.values["event"] = "Frenna"; w.values["location"] = "Ziggo Dome"; w.values["city"] = "Amsterdam"; w.date = "2025-11-29"
            check(w.value("headline") == "Frenna at Ziggo Dome Amsterdam", "preset headline equals the archive")
            check(w.value("caption") == "Frenna, Ziggo Dome, Amsterdam, on 29-11-2025. Photo by Wouter Vellekoop", "preset caption equals the archive")
            check(w.list("keywords").joined(separator: "; ") == "concert; live music; stage; lights; music photography; Frenna; Ziggo Dome; Amsterdam; Wouter Vellekoop", "preset keywords equal the archive")
            check(w.fileName(photo: camera, seq: 1) + ".cr3" == "2025-11-29_21-04-37_Frenna-Ziggo-Dome-Amsterdam_Wouter-Vellekoop_3777.cr3", "preset file name: \(w.fileName(photo: camera, seq: 1))")
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
        check(photos.map(\.captureDate) == photos.map(\.captureDate).sorted(), "sorted by capture time")
        if portraitIndex != nil {
            check(photos.contains { Orientation.swapsAxes($0.orientation) }, "portrait photo keeps its orientation on the card")
        }
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

        // 8b. two frames in the same second: the frame number keeps them apart and in shooting order (planned only)
        let burst = work.appendingPathComponent("burst")
        try? fm.createDirectory(at: burst, withIntermediateDirectories: true)
        try? fm.copyItem(at: files[picks[0]], to: burst.appendingPathComponent("_V1_2001.CR3"))
        try? fm.copyItem(at: files[picks[0]], to: burst.appendingPathComponent("_V1_2002.CR3"))
        let pair = Scanner.load(Scanner.group(Scanner.collectFiles([burst]))) { _ in }
        let burstPlan = FileOps.planRename(pair) { p, n in d.fileName(photo: p, seq: n) }
        let burstNames = burstPlan.items.map { $0.main.lastPathComponent }
        check(burstNames.count == 2 && burstNames.allSatisfy { !$0.contains("-2.") } && burstNames == burstNames.sorted()
              && burstNames.first?.hasSuffix("_2001.cr3") == true,
              "same second, names in shooting order: \(burstNames.joined(separator: ", "))")

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

        // 10b. an interrupted copy never sits under the real name: a leftover temporary file is replaced
        let resume = work.appendingPathComponent("resume")
        let one = Scanner.load(Scanner.group(Scanner.collectFiles([work.appendingPathComponent("card")]))) { _ in }
        if let first = one.first {
            let planned = FileOps.planIngest([first], to: resume) { p, n in v.fileName(photo: p, seq: n) }
            try? fm.createDirectory(at: resume, withIntermediateDirectories: true)
            if let job = planned.first {
                let partial = resume.appendingPathComponent("." + job.main.lastPathComponent + ".pitpick-partial")
                try? Data(count: 1000).write(to: partial)   // what a power cut halfway would leave
                let res = FileOps.ingest([first], to: resume, name: { p, n in v.fileName(photo: p, seq: n) }, metadata: nil,
                                         cancelled: { false }, onPhoto: { _ in })
                let left = ((try? fm.contentsOfDirectory(atPath: resume.path)) ?? []).sorted()
                check(res.copied == 1 && res.suffixed == 0 && left.contains(job.main.lastPathComponent) && !left.contains { $0.hasPrefix(".") || $0.contains("-2.") }
                      && FileOps.fileSize(job.main) == FileOps.fileSize(first.url),
                      "resume after a power cut: complete copy under the real name, no -2, no temporary file left (\(left.joined(separator: ", ")))")
            }
        }

        // 10c. XMP inside a JPG is found (first 256 KB) and read back
        if let jpg = ImageDecoder.readJPEG(SourceRef(id: 0, url: files[0], kind: .cr3, cr3: infos[0]), preview: true) {
            let jdir = work.appendingPathComponent("jpg")
            try? fm.createDirectory(at: jdir, withIntermediateDirectories: true)
            let jurl = jdir.appendingPathComponent("IMG_0001.JPG")
            try? jpg.write(to: jurl)
            _ = ExifTool.shared.run([["-overwrite_original"] + Metadata.stateArgs(tagged: true, rating: 4, label: .green, original: nil, labelNames: v.labelNames) + [jurl.path]])
            let back = Scanner.load(Scanner.group(Scanner.collectFiles([jdir]))) { _ in }
            check(back.first.map { $0.kind == .embedded && $0.tagged && $0.rating == 4 && $0.label == .green } ?? false,
                  "tag, stars and label read back from inside a JPG")
        }

        // 10e. incremental ingest: what was ingested before is skipped, also into another job folder
        let incCard = work.appendingPathComponent("inccard/DCIM/100EOSR5")
        try? fm.createDirectory(at: incCard, withIntermediateDirectories: true)
        for (k, i) in files.indices.prefix(3).enumerated() { try? fm.copyItem(at: files[i], to: incCard.appendingPathComponent("_V1_900\(k).CR3")) }
        let history = IngestHistory(file: work.appendingPathComponent("ingested.txt"))
        let inc1 = Scanner.load(Scanner.group(Scanner.collectFiles([work.appendingPathComponent("inccard")]))) { _ in }
        let ri = FileOps.ingest(inc1, to: work.appendingPathComponent("jobA/raw"), name: { p, n in v.fileName(photo: p, seq: n) }, metadata: nil,
                                cancelled: { false }, history: history, onPhoto: { _ in })
        let reread = IngestHistory(file: history.file)
        check(ri.copied == 3 && reread.count == 3, "incremental ingest: 3 photos remembered (\(reread.count) in the history after a restart)")
        check(inc1.filter { !reread.contains($0) }.isEmpty, "the same card again, into another job folder: nothing new to copy")
        if files.count > 3 { try? fm.copyItem(at: files[3], to: incCard.appendingPathComponent("_V1_9003.CR3")) }
        let inc2 = Scanner.load(Scanner.group(Scanner.collectFiles([work.appendingPathComponent("inccard")]))) { _ in }
        let fresh = inc2.filter { !reread.contains($0) }
        check(fresh.count == 1 && fresh.first?.name == "_V1_9003.CR3", "one new photo on the card: only that one is new (\(fresh.map { $0.name }.joined()))")

        // 10g. protected in the camera: locked on the card, tagged when read from a card, copied first, and the copy is
        //      not locked; stars given in the camera are read from the CR3
        let protCard = work.appendingPathComponent("protcard/DCIM/100EOSR5")
        try? fm.createDirectory(at: protCard, withIntermediateDirectories: true)
        for (k, i) in files.indices.prefix(4).enumerated() { try? fm.copyItem(at: files[i], to: protCard.appendingPathComponent("_V1_950\(k).CR3")) }
        let lockedFile = protCard.appendingPathComponent("_V1_9502.CR3")
        let ratedFile = protCard.appendingPathComponent("_V1_9503.CR3")
        var ratedOK = false
        if let h = try? FileHandle(forUpdating: ratedFile), let head = try? h.read(upToCount: 300_000),
           let r = head.range(of: Data("<xmp:Rating>0<".utf8)) {
            try? h.seek(toOffset: UInt64(r.lowerBound + 12))
            try? h.write(contentsOf: Data("4".utf8))
            try? h.close()
            ratedOK = true
        }
        chflags(lockedFile.path, UInt32(UF_IMMUTABLE))
        let wasLockedIsTagged = Scanner.lockedIsTagged
        Scanner.lockedIsTagged = true
        let protGroups = Scanner.group(Scanner.collectFiles([work.appendingPathComponent("protcard")]))
        let prot = Scanner.load(protGroups, onCard: true) { _ in }
        let notCard = Scanner.load(protGroups) { _ in }
        Scanner.lockedIsTagged = wasLockedIsTagged
        let lp = prot.first { $0.name == "_V1_9502.CR3" }
        check(lp?.locked == true && lp?.tagged == true && prot.filter { $0.tagged }.count == 1
              && notCard.first { $0.name == "_V1_9502.CR3" }?.tagged == false,
              "protected in the camera: locked, and tagged when read from a card (not elsewhere)")
        check(ratedOK && prot.first { $0.name == "_V1_9503.CR3" }?.rating == 4 && prot.filter { $0.rating > 0 }.count == 1,
              "stars given in the camera are read from the CR3")
        var firstNames: [String] = []
        var lockedCopy: URL?
        let rp = FileOps.ingest(prot, to: work.appendingPathComponent("jobP/raw"), name: { p, n in v.fileName(photo: p, seq: n) },
                                metadata: nil, cancelled: { false }, priority: Controller.isMarked,
                                onPhoto: { p in
                                    firstNames.append(p.originalFileName)
                                    if p.originalFileName == "_V1_9502.CR3" { lockedCopy = p.url }
                                })
        check(rp.copied == 4 && rp.errors.isEmpty && Set(firstNames.prefix(2)) == ["_V1_9502.CR3", "_V1_9503.CR3"],
              "tagged and rated photos are copied first (\(firstNames.joined(separator: " ")))\(rp.errors.first.map { ": " + $0 } ?? "")")
        check(lockedCopy.map { fm.fileExists(atPath: $0.path) && !Scanner.isLocked($0) } == true,
              "the copy of a protected photo is not locked and has its real name")
        chflags(lockedFile.path, 0)

        // 10h. camera clocks: the serial number is read, a correction moves the capture time and the names, but never
        //      the key of the ingest history; the corrected time goes into the XMP
        if let cp = prot.first {
            let key = IngestHistory.key(cp)
            let before = cp.shootTime
            cp.clockOffset = 72
            let after = cp.shootTime
            let args = v.metadataArgs(photo: cp, seq: 1)
            check(cp.body != nil && IngestHistory.key(cp) == key && before != after
                  && args.contains { $0.hasPrefix("-XMP-exif:DateTimeOriginal=") },
                  "clock per body: \(cp.body ?? "no serial number"), \(before) + 1:12 = \(after); history key unchanged; capture time in the XMP")
            cp.clockOffset = 0
        }
        check(ExifDate.parseOffset("+1:12") == 72 && ExifDate.parseOffset("-0:01:12") == -72 && ExifDate.parseOffset("1m12s") == 72
              && ExifDate.parseOffset("-5") == -5 && ExifDate.offsetText(-72) == "-0:01:12", "clock corrections are read and written as text")

        // 10i. the camera's JPEG out of a CR3: full size as it is, 2048 px smaller, both with the Adobe RGB profile
        //      and the camera's EXIF; time per photo
        for (folder, edge) in [("exp-full", 0), ("exp-2048", 2048)] {
            let dir = work.appendingPathComponent(folder)
            let te = nowMs()
            let res = Export.run(prot, to: dir, name: { p, n in v.fileName(photo: p, seq: n) }, longEdge: edge == 0 ? nil : edge,
                                 progress: { _ in }, cancelled: { false })
            let tJPEG = nowMs() - te
            let meta = ExifTool.shared.run(res.done.enumerated().map { i, item in Export.metadataCommand(item, fields: v.metadataArgs(photo: item.photo, seq: i + 1)) })
            let tAll = nowMs() - te
            var sizesOK = true, profileOK = true
            for item in res.done {
                guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { sizesOK = false; continue }
                let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                if edge == 0 ? w < 6000 : max(w, h) != edge { sizesOK = false }
                if item.adobeRGB && (props[kCGImagePropertyProfileName] as? String ?? "") != "Adobe RGB (1998)" { profileOK = false }
            }
            check(res.done.count == prot.count && res.errors.isEmpty && meta.allSatisfy { $0.ok } && sizesOK && profileOK,
                  "camera JPEG \(edge == 0 ? "full size" : "\(edge) px"): \(res.done.count) in \(ms(tJPEG)) (\(ms(tJPEG / Double(max(1, res.done.count)))) each), with metadata \(ms(tAll)); size, profile and EXIF right")
        }

        // 10j. a second copy during the ingest, every copy checked against the card: both copies byte for byte the same
        //      as the source, the XMP in both, file dates as on the card
        var copiesB: [String: URL] = [:]
        let rb = FileOps.ingest(prot, to: work.appendingPathComponent("jobB/raw"), name: { p, n in v.fileName(photo: p, seq: n) },
                                metadata: { p in v.metadataArgs(photo: p, seq: 1) + Metadata.stateArgs(p, labelNames: v.labelNames) },
                                cancelled: { false }, backup: work.appendingPathComponent("backupB/raw"), verify: true,
                                onPhoto: { p in copiesB[p.originalFileName] = p.url })
        let mainFiles = ((try? fm.contentsOfDirectory(atPath: work.appendingPathComponent("jobB/raw").path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let backFiles = ((try? fm.contentsOfDirectory(atPath: work.appendingPathComponent("backupB/raw").path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        var sameBytes = !mainFiles.isEmpty
        for f in mainFiles {
            let a = try? Data(contentsOf: work.appendingPathComponent("jobB/raw/" + f)), b = try? Data(contentsOf: work.appendingPathComponent("backupB/raw/" + f))
            if a == nil || a != b { sameBytes = false }
        }
        let srcCR3 = prot.first { $0.name.hasSuffix(".CR3") }
        let copyCR3 = srcCR3.flatMap { copiesB[$0.originalFileName] }
        let sameAsCard = srcCR3.flatMap { s in copyCR3.map { (try? Data(contentsOf: s.url)) == (try? Data(contentsOf: $0)) } } ?? false
        let sameDate = srcCR3.flatMap { s in copyCR3.map {
            ((try? fm.attributesOfItem(atPath: s.url.path))?[.modificationDate] as? Date) == ((try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date)
        } } ?? false
        check(rb.copied == prot.count && rb.errors.isEmpty && mainFiles == backFiles && mainFiles.filter { $0.hasSuffix(".xmp") }.count == prot.count
              && sameBytes && sameAsCard && sameDate,
              "second copy, checked: \(mainFiles.count) files in both folders, byte for byte the same, XMP in both, dates as on the card\(rb.errors.first.map { ": " + $0 } ?? "")"
              + (sameAsCard && sameDate ? "" : " [card \(sameAsCard) date \(sameDate) copy \(copyCR3?.lastPathComponent ?? "-") src \(srcCR3?.name ?? "-") keys \(copiesB.keys.sorted())]"))

        // 10k. who is in one photo, and code replacements: \jb\ becomes James Bay in the field, per photo, in the
        //      caption through {personshown}, and in the XMP
        let codeFile = work.appendingPathComponent("codes.txt")
        try? "jb\tJames Bay\nms\tMarcus Smith\n".write(to: codeFile, atomically: true, encoding: .utf8)
        let nCodes = Codes.load(codeFile.path)
        var cv = v
        cv.values["personshown"] = "\\jb\\"
        cv.values["caption"] = "{personshown} at {location}"
        let onePhoto = prot[0]
        let jobCaption = cv.value("caption", photo: onePhoto)
        onePhoto.people = ["\\ms\\", "\\jb\\"]
        let photoCaption = cv.value("caption", photo: onePhoto)
        let peopleArgs = cv.metadataArgs(photo: onePhoto, seq: 1).filter { $0.hasPrefix("-XMP-iptcExt:PersonInImage=") }
        check(nCodes == 2 && cv.value("personshown") == "James Bay" && jobCaption.hasPrefix("James Bay at")
              && photoCaption.hasPrefix("Marcus Smith; James Bay at")
              && peopleArgs == ["-XMP-iptcExt:PersonInImage=Marcus Smith", "-XMP-iptcExt:PersonInImage=James Bay"]
              && Codes.expand("\\xx\\ stays") == "\\xx\\ stays",
              "person per photo and code replacements: \(photoCaption)")
        onePhoto.people = nil
        Codes.load("")

        // 10l. the index of a folder (used for the NAS): the second reading takes everything from it, with the same
        //      dates, tags and stars; a photo whose XMP changed is read again
        let idxDir = work.appendingPathComponent("index")
        let idxRoot = [work.appendingPathComponent("jobB/raw")]
        let (f1, s1) = Scanner.collectFilesWithStamps(idxRoot)
        let index1 = FolderIndex(roots: idxRoot, directory: idxDir)
        let read1 = Scanner.load(Scanner.group(f1), index: index1, stamps: s1) { _ in }
        index1.save()
        let index2 = FolderIndex(roots: idxRoot, directory: idxDir)
        let read2 = Scanner.load(Scanner.group(f1), index: index2, stamps: s1) { _ in }
        func same(_ a: Photo, _ b: Photo) -> Bool {
            a.url == b.url && a.cameraDate == b.cameraDate && a.tagged == b.tagged && a.rating == b.rating && a.label == b.label
                && a.originalFileName == b.originalFileName && a.orientation == b.orientation && a.body == b.body
                && a.cr3?.jpegOffset == b.cr3?.jpegOffset && a.cr3?.prvwLength == b.cr3?.prvwLength && a.sidecar == b.sidecar
        }
        let allSame = read1.count == read2.count && zip(read1, read2).allSatisfy { same($0, $1) }
        var readAgain = false
        if let changed = read2.first(where: { $0.sidecar != nil }), let x = changed.sidecar {
            _ = ExifTool.shared.run([["-overwrite_original", "-XMP-xmp:Rating=5", x.path]])
            let (f3, s3) = Scanner.collectFilesWithStamps(idxRoot)
            index2.save()
            let index3 = FolderIndex(roots: idxRoot, directory: idxDir)
            let read3 = Scanner.load(Scanner.group(f3), index: index3, stamps: s3) { _ in }
            readAgain = read3.first { $0.url == changed.url }?.rating == 5 && index3.used == read3.count - 1
        }
        check(index2.used == read2.count && allSame && readAgain,
              "folder index: \(index2.used) of \(read2.count) photos from the index, the same as read from the files; a changed XMP is read again")

        // 10f. filters on stars and labels, and a selection that only keeps what is shown
        if inc2.count >= 4 {
            let fs = Session()
            let fp = inc2
            fp[0].rating = 4; fp[1].rating = 2; fp[2].rating = 5; fp[2].label = .red; fp[3].label = .red
            fs.setPhotos(fp, roots: [])
            fs.minRating = 3; fs.rebuildVisible(keeping: nil)
            let stars = fs.visible.count == 2 && fs.visible.allSatisfy { $0.rating >= 3 }
            fs.minRating = 0; fs.labelFilter = .red; fs.rebuildVisible(keeping: nil)
            let label = fs.visible.count == 2 && fs.visible.allSatisfy { $0.label == .red }
            fs.labelFilter = nil; fs.rebuildVisible(keeping: nil)
            fs.selection = Set(fs.visible.map { ObjectIdentifier($0) })
            fs.scope = .selected
            fs.minRating = 3; fs.rebuildVisible(keeping: fp[0])
            let pruned = fs.selection.count == 2 && fs.scope == .selected
            fs.selection = [ObjectIdentifier(fp[0])]
            check(stars && label && pruned && fs.scope == .tagged, "filters on stars and labels; a selection keeps only the photos shown")
            fs.currentIndex = 0
            fp[0].rating = 0; fs.rebuildVisible(keeping: fp[0])
            check(fs.currentPhoto === fp[2], "a photo that drops out of the filter: the next one shown becomes current")
        }

        // 10d. a folder on the Mac's own disk is not a memory card (so tags are saved there)
        check(!CardWatcher.isOnCard(work) && !CardWatcher.isCard(URL(fileURLWithPath: "/")), "the Mac's own disk is not taken for a memory card")

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

/// Mean difference per colour channel (0-255) between two images of the same size, on a 1/8 grid.
func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
    let w = max(1, a.width / 8), h = max(1, a.height / 8)
    func pixels(_ i: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
    let pa = pixels(a), pb = pixels(b)
    var sum = 0
    for i in stride(from: 0, to: pa.count, by: 4) {
        sum += abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
    }
    return Double(sum) / Double(w * h * 3)
}

enum Bench {
    /// --bench-ingest <dest> <card> [card...]: ingests the cards twice, without and with XMP, and prints the time.
    static func ingest(_ args: [String]) -> Int32 {
        guard args.count >= 2 else { print("usage: --bench-ingest <dest> <card> [card...]"); return 2 }
        let dest = URL(fileURLWithPath: args[0])
        let sources = Scanner.load(Scanner.group(Scanner.collectFiles(args.dropFirst().map { URL(fileURLWithPath: $0) }))) { _ in }
        var v = SelfTest.examplePad()
        v.fileTemplate = PadValues().fileTemplate
        v.spacesToDashes = true
        for (label, withXMP) in [("copy only", false), ("copy + XMP", true)] {
            let d = dest.appendingPathComponent(withXMP ? "with-xmp" : "copy-only")
            let t0 = nowMs()
            var order: [Int] = []
            let r = FileOps.ingest(sources, to: d, name: { p, n in v.fileName(photo: p, seq: n) },
                                   metadata: withXMP ? { p in v.metadataArgs(photo: p, seq: 1) + Metadata.stateArgs(p, labelNames: v.labelNames) } : nil,
                                   cancelled: { false }, onPhoto: { order.append($0.id) })
            let dt = nowMs() - t0
            let streams = Set(sources.map { FileOps.volumeKey($0.url) }).count
            print("\(label): \(streams) card(s) at once, handed over in capture order: \(order == order.sorted() && order.count == sources.count)")
            print("\(label): \(r.copied) photos, \(String(format: "%.2f", Double(r.bytes) / 1e9)) GB in \(ms(dt)), \(String(format: "%.0f", Double(r.bytes) / 1e6 / (dt / 1000))) MB/s, \(String(format: "%.1f", dt / Double(max(1, r.copied)))) ms per photo")
        }
        ExifTool.shared.stop()
        return 0
    }

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

        for rate in [4.0, 8.0, 15.0, 25.0, 40.0] {
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
    /// Screenshots render the layers with CALayer.render(in:), which does not draw IOSurface contents.
    static var capturing = false
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
        capturing = true
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
        capturing = true
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
