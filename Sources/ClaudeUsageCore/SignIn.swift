import Foundation
import Network

/// Browser sign-in that creates this app's own grant (`AppGrant`).
///
/// Standard OAuth PKCE with a loopback redirect: open the authorize page, catch
/// the redirect on localhost, exchange the code. The result is a grant only this
/// app holds, so renewing it later cannot affect Claude Code.
public struct SignIn: Sendable {
    /// The loopback redirect DSH uses with the same client.
    static let port: NWEndpoint.Port = 53692
    static let redirectURI = "http://localhost:53692/callback"
    static let timeout: Duration = .seconds(300)

    private let oauth: ClaudeOAuth
    private let store: AppGrantStoring

    public init(oauth: ClaudeOAuth = ClaudeOAuth(), store: AppGrantStoring = KeychainAppGrantStore()) {
        self.oauth = oauth
        self.store = store
    }

    /// - Parameter open: shows the authorize URL to the user, normally by
    ///   opening the default browser.
    public func run(open: @Sendable (URL) -> Void) async throws -> AppGrant {
        let verifier = PKCE.randomURLSafe()
        // Same length as the verifier, as in DSH's known-good request; a
        // separate value so the verifier never appears in a URL.
        let state = PKCE.randomURLSafe()

        let server = try await LoopbackCallbackServer.start(port: Self.port, expectedState: state)
        defer { server.stop() }

        open(oauth.authorizationURL(
            challenge: PKCE.challenge(for: verifier),
            state: state,
            redirectURI: Self.redirectURI
        ))

        let callback = try await server.waitForCallback(timeout: Self.timeout)
        let grant = try await oauth.exchange(
            code: callback.code,
            state: state,
            verifier: verifier,
            redirectURI: Self.redirectURI
        )
        try store.save(grant)
        return grant
    }
}

/// A one-shot HTTP listener on loopback that captures the OAuth redirect.
final class LoopbackCallbackServer: @unchecked Sendable {
    struct Callback: Sendable {
        let code: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ClaudeUsage.SignInCallback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Callback, Error>?
    private let expectedState: String
    private var pending: Result<Callback, Error>?

    private init(listener: NWListener, expectedState: String) {
        self.listener = listener
        self.expectedState = expectedState
    }

    static func start(port: NWEndpoint.Port, expectedState: String) async throws -> LoopbackCallbackServer {
        let parameters = NWParameters.tcp
        // Loopback only: never reachable from the network.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw OAuthError.callbackFailed("could not listen on port \(port): \(error.localizedDescription)")
        }
        let server = LoopbackCallbackServer(listener: listener, expectedState: expectedState)
        try await server.waitUntilReady()
        return server
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { ready.resume() }
                case .failed(let error):
                    once.run { ready.resume(throwing: OAuthError.callbackFailed("port \(SignIn.port) is busy (\(error.localizedDescription))")) }
                case .cancelled:
                    once.run { ready.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: Duration) async throws -> Callback {
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(OAuthError.callbackFailed("timed out waiting for the browser")))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pending {
                    lock.unlock()
                    continuation.resume(with: pending)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<Callback, Error>) {
        lock.lock()
        guard let continuation else {
            if pending == nil { pending = result }
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let (status, message, result) = self.interpret(data ?? Data())
            let html = """
            <!doctype html><meta charset="utf-8"><title>Claude Usage</title>
            <body style="font:15px -apple-system,sans-serif;padding:48px;text-align:center">
            <p>\(message)</p></body>
            """
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if let result { self.finish(result) }
        }
    }

    /// Parses the request line. Returns the HTTP status, a page message, and a
    /// result when the request settles the sign-in (stray requests do not).
    private func interpret(_ data: Data) -> (String, String, Result<Callback, Error>?) {
        let head = String(decoding: data.prefix(8 * 1024), as: UTF8.self)
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost\(parts[1])"),
              components.path == "/callback"
        else {
            return ("404 Not Found", "Not found.", nil)
        }
        func value(_ name: String) -> String? {
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        if let error = value("error") {
            return ("400 Bad Request", "Sign-in did not complete. You can close this tab.",
                    .failure(OAuthError.callbackFailed(error)))
        }
        guard let code = value("code"), !code.isEmpty, let state = value("state"), state == expectedState else {
            return ("400 Bad Request", "This sign-in link is invalid or stale.", nil)
        }
        return ("200 OK", "Claude Usage is signed in. You can close this tab.", .success(Callback(code: code)))
    }
}

/// Runs a closure at most once across threads.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        lock.unlock()
        body()
    }
}
