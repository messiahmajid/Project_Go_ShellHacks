import Foundation

/// Append-only JSON-lines logs under `~/Library/Logs/Go`, written on a
/// background queue so logging never blocks the main thread.
nonisolated enum MeasurementLogFile {
    private static let writeQueue = DispatchQueue(label: "Go.MeasurementLogFile", qos: .utility)

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Go", isDirectory: true)
    }

    /// One sorted-key JSON object without its newline, or nil if it can't be encoded.
    static func jsonLine(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func appendJSONLine(_ object: [String: Any], toFileNamed fileName: String) {
        guard let line = jsonLine(object) else {
            print("⚠️ MeasurementLogFile: a \(fileName) line was not valid JSON and was dropped")
            return
        }
        writeQueue.async {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            appendOwnerOnly(Data((line + "\n").utf8), to: directoryURL.appendingPathComponent(fileName))
        }
    }

    /// Created with mode 0600 and narrowed on every append: the logs are private.
    @discardableResult
    static func appendOwnerOnly(_ data: Data, to fileURL: URL) -> Bool {
        let fileDescriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fileDescriptor >= 0 else { return false }
        fchmod(fileDescriptor, 0o600)
        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        return (try? fileHandle.write(contentsOf: data)) != nil
    }

}
