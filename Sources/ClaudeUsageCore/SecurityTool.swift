import Foundation

/// Runs `/usr/bin/security`.
///
/// Keychain access goes through this tool instead of `SecItem*` because Claude
/// Code creates its item with the tool, so the item's ACL always trusts it. A
/// direct `SecItemCopyMatching` call needs a per-binary "Always Allow" grant,
/// which Claude Code drops every time it rewrites the item, re-prompting for
/// the login password every few hours.
enum SecurityTool {
    static let path = "/usr/bin/security"
    /// `security` exits with this when the item does not exist
    /// (errSecItemNotFound truncated to a byte).
    static let itemNotFoundExitCode: Int32 = 44

    struct Output {
        let status: Int32
        let stdout: Data

        /// stdout as trimmed text, the form `find-generic-password -w` prints.
        var text: String {
            String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// - Parameter input: fed to stdin. Secrets go here, never in `arguments`,
    ///   because arguments are visible to every process through `ps`.
    static func run(_ arguments: [String], input: Data? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        // Drain before waiting so a large item cannot fill the pipe and stall.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: data)
    }
}
