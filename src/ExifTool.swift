// One exiftool process that keeps running (-stay_open), so every write takes milliseconds.
// Pitpick only writes XMP: a .xmp next to a raw, inside the file for JPG/DNG/HEIC.
import Foundation

final class ExifTool {
    static let shared = ExifTool()

    struct Result {
        let ok: Bool
        let text: String
    }

    private let queue = DispatchQueue(label: "nl.wouter.pitpick.exiftool", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outBuffer = Data()
    private var errBuffer = Data()
    private let errLock = NSLock()
    private var counter = 0

    /// Bundled exiftool (Resources/exiftool) on the system perl, otherwise Homebrew.
    static func locate() -> (String, [String])? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL?.appendingPathComponent("exiftool/exiftool"),
           fm.fileExists(atPath: res.path), fm.isExecutableFile(atPath: "/usr/bin/perl") {
            return ("/usr/bin/perl", [res.path])
        }
        for p in ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"] where fm.isExecutableFile(atPath: p) {
            return (p, [])
        }
        return nil
    }

    var isAvailable: Bool { ExifTool.locate() != nil }

    private func ensureStarted() -> Bool {
        if let p = process, p.isRunning { return true }
        guard let (exe, pre) = ExifTool.locate() else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = pre + ["-stay_open", "True", "-@", "-"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self = self, !d.isEmpty else { return }
            self.errLock.lock()
            self.errBuffer.append(d)
            self.errLock.unlock()
        }
        do { try p.run() } catch { return false }
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        outBuffer = Data()
        return true
    }

    private func readUntil(_ marker: String) -> String? {
        let m = Data(marker.utf8)
        while true {
            if let r = outBuffer.range(of: m) {
                let text = String(data: outBuffer.subdata(in: outBuffer.startIndex..<r.lowerBound), encoding: .utf8) ?? ""
                var end = r.upperBound
                if end < outBuffer.endIndex && outBuffer[end] == 0x0A { end += 1 }
                outBuffer = outBuffer.subdata(in: end..<outBuffer.endIndex)
                return text
            }
            guard let out = output else { return nil }
            let d = out.availableData
            if d.isEmpty { return nil }
            outBuffer.append(d)
        }
    }

    private func takeErrors() -> String {
        errLock.lock()
        let s = String(data: errBuffer, encoding: .utf8) ?? ""
        errBuffer.removeAll()
        errLock.unlock()
        return s
    }

    /// Runs commands one after another (on the exiftool queue) and waits for the result.
    func run(_ commands: [[String]], progress: ((Int) -> Void)? = nil) -> [Result] {
        queue.sync { execute(commands, progress: progress) }
    }

    func runAsync(_ commands: [[String]], done: @escaping ([Result]) -> Void) {
        queue.async {
            let r = self.execute(commands, progress: nil)
            DispatchQueue.main.async { done(r) }
        }
    }

    /// Waits until everything already queued is done.
    func waitIdle() { queue.sync {} }

    private func execute(_ commands: [[String]], progress: ((Int) -> Void)?) -> [Result] {
        guard !commands.isEmpty else { return [] }
        guard ensureStarted(), let input = input else {
            return commands.map { _ in Result(ok: false, text: "exiftool not found") }
        }
        var results: [Result] = []
        var start = 0
        while start < commands.count {
            let chunk = commands[start..<min(start + 20, commands.count)]
            var markers: [Int] = []
            var payload = ""
            for c in chunk {
                counter += 1
                markers.append(counter)
                for a in c { payload += a.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + "\n" }
                payload += "-execute\(counter)\n"
            }
            do {
                try input.write(contentsOf: Data(payload.utf8))
            } catch {
                process?.terminate()
                process = nil
                results += chunk.map { _ in Result(ok: false, text: "exiftool is not responding") }
                start += chunk.count
                continue
            }
            for m in markers {
                guard let text = readUntil("{ready\(m)}") else {
                    process = nil
                    results.append(Result(ok: false, text: "exiftool stopped"))
                    continue
                }
                let err = takeErrors()
                let failed = text.contains("weren't updated") || text.contains("weren't created") || err.contains("Error")
                results.append(Result(ok: !failed, text: (text + err).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            start += chunk.count
            progress?(start)
        }
        return results
    }

    func stop() {
        queue.sync {
            guard let p = process, p.isRunning, let input = input else { return }
            try? input.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
            p.waitUntilExit()
            process = nil
        }
    }
}

/// Writes tag, stars and colour label to the XMP shortly after a key press (batched).
final class StateWriter {
    private var pending: [Int: Photo] = [:]
    private var timer: Timer?
    var enabled = true
    var labelNames: () -> [String] = { ["Red", "Yellow", "Green", "Blue", "Purple"] }
    var onError: ((String) -> Void)?

    func schedule(_ p: Photo) {
        guard enabled else { return }
        pending[p.id] = p
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.flush() }
    }

    func flush(wait: Bool = false) {
        timer?.invalidate()
        timer = nil
        let photos = Array(pending.values)
        pending.removeAll()
        if photos.isEmpty {
            if wait { ExifTool.shared.waitIdle() }
            return
        }
        let names = labelNames()
        let targets = photos.map { $0.metadataTarget }
        let commands = zip(photos, targets).map { p, t in ["-overwrite_original"] + Metadata.stateArgs(p, labelNames: names) + [t.path] }
        let finish: ([ExifTool.Result]) -> Void = { [weak self] results in
            for (i, r) in results.enumerated() where i < photos.count {
                let p = photos[i]
                if r.ok {
                    if p.kind != .embedded && p.sidecar == nil { p.sidecar = targets[i] }
                    p.hasStoredOriginal = true
                } else {
                    self?.onError?("Could not update \(p.name): \(r.text)")
                }
            }
        }
        if wait {
            finish(ExifTool.shared.run(commands))
        } else {
            ExifTool.shared.runAsync(commands, done: finish)
        }
    }
}
