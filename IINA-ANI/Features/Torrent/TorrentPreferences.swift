import Foundation

extension Preferences {
    var torrentUploadLimitBytesPerSecond: UInt32 {
        get {
            let stored = prefs.object(forKey: "torrent.uploadLimitBytesPerSecond") as? Int ?? 65_536
            return UInt32(min(max(stored, 1), Int(TorrentUploadPolicy.maximumBytesPerSecond)))
        }
        set {
            prefs.set(Int(min(max(newValue, 1), TorrentUploadPolicy.maximumBytesPerSecond)), forKey: "torrent.uploadLimitBytesPerSecond")
        }
    }

    var torrentUploadConsentAcknowledged: Bool {
        prefs.bool(forKey: "torrent.uploadConsentAcknowledged")
    }

    func saveTorrentUploadPolicy(_ policy: TorrentUploadPolicy) {
        torrentUploadLimitBytesPerSecond = policy.bytesPerSecond
        prefs.set(policy.acknowledged, forKey: "torrent.uploadConsentAcknowledged")
    }
}
