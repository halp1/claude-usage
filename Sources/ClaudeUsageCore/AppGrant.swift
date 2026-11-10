import Foundation

/// This app's own OAuth grant, separate from Claude Code's.
///
/// Refresh tokens are single-use, so renewing a grant invalidates every other
/// copy of it. Renewing Claude Code's grant once logged Claude Code out into a
/// `/login` loop. This grant comes from the app's own browser sign-in, so the
/// app can renew it freely: Claude Code never holds a copy. DSH's subscription
/// plugin works the same way.
public struct AppGrant: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Renew a few minutes early so a request started now cannot outlive it.
    public func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

public protocol AppGrantStoring: Sendable {
    func load() throws -> AppGrant?
    func save(_ grant: AppGrant) throws
    func clear() throws
}

public enum AppGrantStoreError: Error, LocalizedError {
    case unreadable(String)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "Could not read this app's sign-in: \(detail)."
        case .writeFailed(let code):
            return "Could not save this app's sign-in (security exited with \(code))."
        }
    }
}

/// Stores the grant in the app's own login-keychain item.
///
/// Every access goes through `/usr/bin/security`, so the item's ACL trusts that
/// tool and no access ever prompts for a password. The token is passed on stdin
/// (`security -i`), never as an argument, where `ps` would show it.
public struct KeychainAppGrantStore: AppGrantStoring {
    /// Deliberately distinct from Claude Code's item; see `AppGrant`.
    public static let service = "com.claudeusage.oauth"
    /// `security -i` reads commands into a fixed line buffer of about 4 KB.
    static let maxCommandLength = 3500

    private let account: String

    public init(account: String = NSUserName()) {
        self.account = account
    }

    public func load() throws -> AppGrant? {
        let output = try SecurityTool.run(["find-generic-password", "-s", Self.service, "-a", account, "-w"])
        switch output.status {
        case 0:
            do {
                return try JSONDecoder().decode(AppGrant.self, from: Data(output.text.utf8))
            } catch {
                throw AppGrantStoreError.unreadable("stored grant is not valid JSON")
            }
        case SecurityTool.itemNotFoundExitCode:
            return nil
        default:
            throw AppGrantStoreError.unreadable("security exited with \(output.status)")
        }
    }

    public func save(_ grant: AppGrant) throws {
        guard !account.contains("\""), !account.contains("\n") else {
            throw AppGrantStoreError.unreadable("unsupported account name")
        }
        let hex = try JSONEncoder().encode(grant).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(Self.service)\" -a \"\(account)\" -X \(hex)\n"
        guard command.utf8.count < Self.maxCommandLength else {
            throw AppGrantStoreError.writeFailed(-1)
        }
        let output = try SecurityTool.run(["-i"], input: Data(command.utf8))
        guard output.status == 0 else { throw AppGrantStoreError.writeFailed(output.status) }
        // `security -i` can report success on a partial line; trust only a read-back.
        guard try load() == grant else { throw AppGrantStoreError.writeFailed(0) }
    }

    public func clear() throws {
        let output = try SecurityTool.run(["delete-generic-password", "-s", Self.service, "-a", account])
        guard output.status == 0 || output.status == SecurityTool.itemNotFoundExitCode else {
            throw AppGrantStoreError.writeFailed(output.status)
        }
    }
}
