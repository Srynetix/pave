import Foundation

/// Runs a program and collects its output. Both pipes are drained before
/// waiting (a full pipe would block the child). Never through a shell: the
/// arguments go as they are.
public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var error: Data
        public var text: String { String(decoding: output, as: UTF8.self) }
        public var errorText: String { String(decoding: error, as: UTF8.self) }
    }

    public static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Result
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // stderr on another thread, stdout here; the group wait makes the
        // unsynchronised variable safe to read afterwards.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: data, error: errorData)
    }
}
