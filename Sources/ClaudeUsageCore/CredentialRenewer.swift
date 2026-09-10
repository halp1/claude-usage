import Foundation

/// Asks the Claude Code CLI to renew the credential it owns.
///
/// This app must never refresh the shared OAuth grant itself: refresh tokens are
/// single-use, so rotating one invalidates the copy a running Claude Code holds
/// in memory, logging the user out into a `/login` loop. Claude Code renewing
/// its own grant is the ordinary path and updates its own state, so the fix is
/// to delegate rather than to synchronize.
///
/// `auth status` is used because it touches authentication, runs in well under a
/// second, and makes no inference request — it consumes no usage.
public protocol CredentialRenewing: Sendable {
    /// Runs a renewal attempt. Failure is not fatal: the caller falls back to
    /// showing the last known values.
    func renew() async
}

public struct ClaudeCLIRenewer: CredentialRenewing {
    /// Locations to try, in order, before falling back to `PATH`.
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public static func executableURL() -> URL? {
        let manager = FileManager.default
        for path in searchPaths where manager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // A GUI app launched at login inherits a minimal PATH, so resolve via a
        // login shell rather than assuming the CLI is already reachable.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, manager.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    public func renew() async {
        guard let executable = Self.executableURL() else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["auth", "status"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return
        }

        // Never let a wedged CLI hold the refresh loop open.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            process.terminate()
        }
    }
}
