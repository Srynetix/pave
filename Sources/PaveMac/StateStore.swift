import Foundation
import PaveCore
import PaveIPC

/// Persists the workspace state after every change, so parked windows can be
/// brought back even after a `kill -9` (restored at next launch, M0 / H4).
public struct StateStore: Sendable {
    struct Persisted: Codable {
        var savedAt: Date
        var workspaces: Workspaces
        /// App name per parked window, for humans reading the file. No titles.
        var apps: [String: String]
    }

    public let url: URL

    public init(url: URL = StateFiles.url("state.json"))
    {
        self.url = url
    }

    public func load() -> Workspaces? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder.pave.decode(Persisted.self, from: data).workspaces
        } catch {
            Log.info("state file unreadable (\(error)), ignored")
            return nil
        }
    }

    public func save(_ workspaces: Workspaces, appNames: [WindowID: String]) {
        let apps = Dictionary(
            uniqueKeysWithValues: workspaces.savedFrames.keys.map { ("\($0.rawValue)", appNames[$0] ?? "?") })
        let persisted = Persisted(savedAt: Date(), workspaces: workspaces, apps: apps)
        do {
            try StateFiles.write(JSONEncoder.pave.encode(persisted), to: url)
        } catch {
            Log.info("cannot save state: \(error)")
        }
    }
}

extension JSONEncoder {
    static var pave: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var pave: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
