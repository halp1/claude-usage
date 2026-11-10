import Foundation

/// One OAuth grant this app holds, created by its own browser sign-in.
///
/// Refresh tokens are single-use, so renewing a grant invalidates every other
/// copy of it. Every grant here comes from the app's own sign-in, so nothing
/// else holds a copy and renewing it cannot log another program out.
public struct AppGrant: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    /// When the sign-in itself ends. Claude caps a sign-in at about 30 days
    /// however often it is renewed; after this the user has to sign in again.
    /// Absent on grants saved before the app recorded it.
    public var refreshExpiresAt: Date?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, refreshExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshExpiresAt = refreshExpiresAt
    }

    /// Renew a few minutes early so a request started now cannot outlive it.
    public func needsRefresh(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    /// Whether the sign-in has run out, so renewing is pointless.
    public func signInExpired(now: Date = Date()) -> Bool {
        refreshExpiresAt.map { $0 <= now } ?? false
    }
}

/// A signed-in Claude account.
public struct Account: Codable, Equatable, Sendable, Identifiable {
    /// The keychain account name: the email, or the login user name for the
    /// single grant older versions stored before accounts were identified.
    public var key: String
    public var email: String?
    public var organization: String?
    public var grant: AppGrant
    public var addedAt: Date

    public var id: String { key }

    public init(key: String, email: String?, organization: String?, grant: AppGrant, addedAt: Date = Date()) {
        self.key = key
        self.email = email
        self.organization = organization
        self.grant = grant
        self.addedAt = addedAt
    }
}

public protocol AccountStoring: Sendable {
    /// Every stored account, oldest first.
    func list() throws -> [Account]
    func save(_ account: Account) throws
    func remove(key: String) throws
}

public enum AccountStoreError: Error, LocalizedError {
    case unreadable(String)
    case writeFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "Could not read saved sign-ins: \(detail)."
        case .writeFailed(let code):
            return "Could not save the sign-in (security exited with \(code))."
        }
    }
}

/// Stores one login-keychain item per account under the app's own service.
///
/// Every access goes through `/usr/bin/security`, so the items' ACLs trust that
/// tool and no access ever prompts for a password. Tokens are passed on stdin
/// (`security -i`), never as arguments, where `ps` would show them.
public struct KeychainAccountStore: AccountStoring {
    public static let service = "com.claudeusage.oauth"
    /// `security -i` reads commands into a fixed line buffer of about 4 KB.
    static let maxCommandLength = 3500

    private let legacyKey: String

    /// - Parameter legacyKey: the keychain account older versions stored their
    ///   single grant under.
    public init(legacyKey: String = NSUserName()) {
        self.legacyKey = legacyKey
    }

    public func list() throws -> [Account] {
        let dump = try SecurityTool.run(["dump-keychain"])
        guard dump.status == 0 else { throw AccountStoreError.unreadable("security exited with \(dump.status)") }
        let keys = Self.accountNames(inDump: dump.text, service: Self.service)
        return try keys.compactMap(load).sorted { $0.addedAt < $1.addedAt }
    }

    public func save(_ account: Account) throws {
        guard Self.isSafeKey(account.key) else { throw AccountStoreError.unreadable("unsupported account name") }
        let hex = try JSONEncoder().encode(account).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \"\(Self.service)\" -a \"\(account.key)\" -X \(hex)\n"
        guard command.utf8.count < Self.maxCommandLength else { throw AccountStoreError.writeFailed(-1) }
        let output = try SecurityTool.run(["-i"], input: Data(command.utf8))
        guard output.status == 0 else { throw AccountStoreError.writeFailed(output.status) }
        // `security -i` can report success on a partial line; trust only a read-back.
        guard try load(account.key) == account else { throw AccountStoreError.writeFailed(0) }
    }

    public func remove(key: String) throws {
        let output = try SecurityTool.run(["delete-generic-password", "-s", Self.service, "-a", key])
        guard output.status == 0 || output.status == SecurityTool.itemNotFoundExitCode else {
            throw AccountStoreError.writeFailed(output.status)
        }
    }

    private func load(_ key: String) throws -> Account? {
        let output = try SecurityTool.run(["find-generic-password", "-s", Self.service, "-a", key, "-w"])
        switch output.status {
        case 0:
            return try Self.decode(Data(output.text.utf8), key: key)
        case SecurityTool.itemNotFoundExitCode:
            return nil
        default:
            throw AccountStoreError.unreadable("security exited with \(output.status)")
        }
    }

    /// Reads an account item, including the bare grant older versions stored.
    static func decode(_ data: Data, key: String) throws -> Account {
        if let account = try? JSONDecoder().decode(Account.self, from: data) {
            return account
        }
        guard let grant = try? JSONDecoder().decode(AppGrant.self, from: data) else {
            throw AccountStoreError.unreadable("stored sign-in is not valid JSON")
        }
        return Account(key: key, email: nil, organization: nil, grant: grant, addedAt: .distantPast)
    }

    /// The account names of every generic-password item for one service in
    /// `security dump-keychain` output, which lists attributes but no secrets.
    static func accountNames(inDump dump: String, service: String) -> [String] {
        var names: [String] = []
        for block in dump.components(separatedBy: "keychain: ") {
            guard block.contains("class: \"genp\""),
                  value(of: "svce", in: block) == service,
                  let account = value(of: "acct", in: block),
                  !names.contains(account)
            else { continue }
            names.append(account)
        }
        return names
    }

    private static func value(of attribute: String, in block: String) -> String? {
        let marker = "\"\(attribute)\"<blob>=\""
        guard let start = block.range(of: marker) else { return nil }
        let rest = block[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func isSafeKey(_ key: String) -> Bool {
        !key.isEmpty && !key.contains("\"") && !key.contains("\n") && !key.contains("\\")
    }
}
