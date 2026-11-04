import Foundation

/// Maps a Claude Code CLI session id (the hook payload's `session_id`) to the
/// Claude Desktop session that hosts it, by reading Desktop's per-session
/// records at `claude-code-sessions/<account>/<org>/local_<id>.json`.
struct ClaudeDesktopSessionLocator {
    private struct Record: Decodable {
        var sessionId: String
        var cliSessionId: String?
        var isArchived: Bool?
    }

    let sessionsRoot: URL

    init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    ) {
        self.sessionsRoot = sessionsRoot
    }

    func desktopSessionID(forCLISessionID cliSessionID: String) -> String? {
        let needle = Data(cliSessionID.utf8)
        guard !needle.isEmpty else { return nil }

        for file in recordFilesNewestFirst() {
            guard let data = try? Data(contentsOf: file),
                  data.range(of: needle) != nil,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.cliSessionId == cliSessionID,
                  record.isArchived != true,
                  record.sessionId.hasPrefix("local_")
            else { continue }
            return record.sessionId
        }
        return nil
    }

    static func continueURL(forDesktopSessionID sessionID: String) -> String? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url?.absoluteString
    }

    private func recordFilesNewestFirst() -> [URL] {
        let fileManager = FileManager.default
        var files: [(url: URL, modified: Date)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey]

        for account in (try? fileManager.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fileManager.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                let entries = (try? fileManager.contentsOfDirectory(at: org, includingPropertiesForKeys: keys)) ?? []
                for entry in entries where entry.lastPathComponent.hasPrefix("local_") && entry.pathExtension == "json" {
                    let modified = (try? entry.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                    files.append((entry, modified))
                }
            }
        }
        return files.sorted { $0.modified > $1.modified }.map(\.url)
    }
}
