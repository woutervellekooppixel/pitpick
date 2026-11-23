// Memory cards: Pitpick notices a card going in (a disk with a DCIM folder that is removable media or
// formatted like a card), lists it at the top of the panel, checked, and you choose: look at it on the
// card, or ingest it. Pitpick writes nothing on a card; tags go along with the ingest.
import AppKit

struct Card: Identifiable, Equatable {
    /// The volume, for example /Volumes/EOS_DIGITAL.
    let url: URL
    let name: String
    /// Photos as Pitpick counts them (a CR3 with its JPG twin is one); nil while counting.
    var photos: Int?
    /// Space in use on the card.
    let usedBytes: Int64
    let locked: Bool
    var checked = true

    var id: String { url.path }
}

final class CardWatcher: ObservableObject {
    @Published private(set) var cards: [Card] = []
    private var observers: [NSObjectProtocol] = []
    /// File access on a card can be slow (a reader waking up), so it never runs on the main thread.
    private let queue = DispatchQueue(label: "nl.wouter.pitpick.cards", qos: .utility)

    static let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
                                            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeTypeNameKey]

    var checked: [Card] { cards.filter { $0.checked } }

    /// A memory card: a local disk with a DCIM folder at the top that is removable media (an SD card, also in a
    /// built-in slot), or an external disk formatted like a card (exFAT or FAT, as cameras do). Not an SSD
    /// with a copy of a card on it, and never a network drive.
    /// Only a disk that looks like a card is opened to look for DCIM, so an external SSD or a network drive
    /// never triggers macOS's question about access to a removable volume.
    static func isCard(_ volume: URL) -> Bool {
        guard let v = try? volume.resourceValues(forKeys: keys), v.volumeIsLocal != false else { return false }
        let fs = (v.volumeTypeName ?? "").lowercased()
        let fat = fs.contains("exfat") || fs.contains("msdos") || fs.contains("fat")
        guard v.volumeIsRemovable == true || (v.volumeIsInternal != true && fat) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The card a folder or file is on (nil when it is not on a memory card).
    static func cardVolume(of url: URL) -> URL? {
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume, isCard(volume) else { return nil }
        return volume
    }

    /// Whether a folder (a card, or a folder on it such as DCIM/100EOSR5) is on a memory card.
    static func isOnCard(_ folder: URL) -> Bool {
        guard let volume = (try? folder.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return false }
        return isCard(volume)
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            if let u = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { self?.check(u) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            if let u = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { self?.remove(u) }
        })
        // cards that were already in when Pitpick started
        queue.async { [weak self] in
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(CardWatcher.keys),
                                                                options: [.skipHiddenVolumes]) ?? []
            DispatchQueue.main.async { volumes.forEach { self?.check($0) } }
        }
    }

    func setChecked(_ id: String, _ on: Bool) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].checked = on
    }

    /// A volume appeared: if it is a card, list it (checked) and count its photos in the background.
    func check(_ volume: URL) {
        let url = volume.standardizedFileURL
        guard !cards.contains(where: { $0.url == url }) else { return }
        queue.async { [weak self] in
            guard CardWatcher.isCard(url) else { return }
            let v = try? url.resourceValues(forKeys: CardWatcher.keys)
            let used = Int64(max(0, (v?.volumeTotalCapacity ?? 0) - (v?.volumeAvailableCapacity ?? 0)))
            let card = Card(url: url, name: v?.volumeName ?? url.lastPathComponent, photos: nil, usedBytes: used,
                            locked: v?.volumeIsReadOnly ?? false)
            DispatchQueue.main.async {
                guard let self = self, !self.cards.contains(where: { $0.url == url }) else { return }
                self.cards.append(card)
            }
            let n = Scanner.group(Scanner.collectFiles([url.appendingPathComponent("DCIM")])).count
            DispatchQueue.main.async {
                guard let self = self, let i = self.cards.firstIndex(where: { $0.url == url }) else { return }
                self.cards[i].photos = n
                if n == 0 { self.cards[i].checked = false }   // an empty card is not worth opening
            }
        }
    }

    func remove(_ volume: URL) {
        let url = volume.standardizedFileURL
        cards.removeAll { $0.url == url }
    }
}
