import Foundation
import Network

// One connection to the AeroSpace server's Unix socket, speaking its framed
// JSON protocol: a UInt32 protocol-version handshake, then length-prefixed
// JSON both ways (4-byte native-endian count + payload). A connection serves
// one of two roles, chosen by the first call after open():
//   - command: send() runs CLI-style commands, strictly one in flight at a
//     time because the stream carries no request ids - answers match
//     requests by order alone.
//   - events: subscribe() turns the stream into server-pushed event frames;
//     the server accepts no further commands on it.
// All Network callbacks are delivered on the main queue; the framework does
// its I/O internally, so nothing here can stall the event tap or timers.
final class AeroSpaceConnection {
    // AeroSpace bumps this integer when the wire format changes; the server
    // answers the handshake with the only version it supports and drops
    // mismatched clients, so a mismatch means "integration off until an
    // AeroSpace release compatible with this code is running".
    static let protocolVersion: UInt32 = 1

    enum OpenError: Error {
        case transport(String)
        case versionMismatch(UInt32)
    }

    enum RequestError: Error, CustomStringConvertible {
        case superseded        // replaced by a newer request with the same coalescing key
        case failed(String)

        var description: String {
            switch self {
            case .superseded: return "superseded"
            case .failed(let reason): return reason
            }
        }
    }

    // Fires once, on any failure after a successful open (EOF, transport
    // error, request timeout). close() suppresses it.
    var onClosed: ((String) -> Void)?

    private let label: String
    private var connection: NWConnection?
    private var closed = false

    private struct Request {
        let args: [String]
        let coalescingKey: String?
        let completion: (Result<AeroSpaceAnswer, RequestError>) -> Void
    }

    // Generous against the observed worst case (~35ms per command on the
    // AeroSpace main thread); expiry means the stream is unsynchronized.
    private let requestTimeout: TimeInterval = 1.5

    private var pending: [Request] = []
    // The request whose answer is being awaited. Kept (not just a flag) so
    // close() can fail its completion: callers rely on completions for
    // fallback focus paths, and a dropped one leaves them hanging.
    private var inFlight: Request?
    private var timeoutWork: DispatchWorkItem?

    init(label: String) {
        self.label = label
    }

    func open(path: String, completion: @escaping (Result<Void, OpenError>) -> Void) {
        let conn = NWConnection(to: NWEndpoint.unix(path: path), using: .tcp)
        connection = conn
        var finished = false
        let finish: (Result<Void, OpenError>) -> Void = { [weak self] result in
            guard !finished else { return }
            finished = true
            if case .failure = result {
                self?.closed = true
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            completion(result)
        }
        // A missing listener surfaces as .waiting, which the framework would
        // retry forever; treat it as failure, like a refused connect.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.handshake(finish)
            case .failed(let error), .waiting(let error):
                finish(.failure(.transport("\(error)")))
            case .setup, .preparing, .cancelled:
                break
            @unknown default:
                break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            finish(.failure(.transport("open timed out")))
        }
        conn.start(queue: .main)
    }

    private func handshake(_ finish: @escaping (Result<Void, OpenError>) -> Void) {
        guard let connection else { return }
        var version = Self.protocolVersion
        connection.send(content: Data(bytes: &version, count: 4), completion: .contentProcessed { error in
            if let error {
                finish(.failure(.transport("\(error)")))
            }
        })
        receiveExact(4) { data in
            guard let data else {
                finish(.failure(.transport("handshake EOF")))
                return
            }
            let serverVersion = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard serverVersion == Self.protocolVersion else {
                finish(.failure(.versionMismatch(serverVersion)))
                return
            }
            finish(.success(()))
        }
    }

    // Queue a command. `coalescingKey` replaces a queued-but-unsent request
    // carrying the same key (its completion fails with .superseded), so a
    // burst of workspace switches collapses to the newest target instead of
    // replaying the whole burst at ~10ms per hop. A timeout closes the whole
    // connection: with no request ids, a stream that may still deliver the
    // lost answer later can never be re-synchronized.
    func send(args: [String],
              coalescingKey: String? = nil,
              completion: @escaping (Result<AeroSpaceAnswer, RequestError>) -> Void) {
        guard !closed, connection != nil else {
            completion(.failure(.failed("connection closed")))
            return
        }
        if let coalescingKey,
           let replaced = pending.firstIndex(where: { $0.coalescingKey == coalescingKey }) {
            pending.remove(at: replaced).completion(.failure(.superseded))
        }
        pending.append(Request(args: args, coalescingKey: coalescingKey, completion: completion))
        pump()
    }

    private func pump() {
        guard inFlight == nil, !closed, let connection, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        inFlight = request

        // windowId/workspace must be present as explicit nulls: the server
        // treats absent keys as a malformed client and appends a warning.
        let body: [String: Any] = [
            "args": request.args, "stdin": "",
            "windowId": NSNull(), "workspace": NSNull(),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            inFlight = nil
            request.completion(.failure(.failed("request encoding failed")))
            return
        }
        sendFrame(payload, on: connection)

        let work = DispatchWorkItem { [weak self] in
            // Detach the request first: fail() -> close() completes whatever
            // is still inFlight, and this request's completion must not run
            // a second time with "connection closed".
            self?.inFlight = nil
            request.completion(.failure(.failed("timed out")))
            self?.fail("request timed out: \(request.args.joined(separator: " "))")
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + requestTimeout, execute: work)

        receiveFrame { [weak self] data in
            guard let self, !self.closed else { return }
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let exitCode = json["exitCode"] as? Int else {
                self.inFlight = nil
                request.completion(.failure(.failed("answer decoding failed")))
                self.fail("bad answer frame")
                return
            }
            self.inFlight = nil
            request.completion(.success(AeroSpaceAnswer(
                exitCode: Int32(exitCode),
                stdout: json["stdout"] as? String ?? "",
                stderr: json["stderr"] as? String ?? "",
                serverVersion: json["serverVersionAndHash"] as? String ?? "?"
            )))
            self.pump()
        }
    }

    // Send the subscribe command and switch to reading pushed event frames
    // forever. On success the server never answers the command itself; a
    // frame without "_event" is a subscribe error answer, which closes the
    // connection like any transport failure.
    func subscribe(to events: [String], onEvent: @escaping ([String: Any]) -> Void) {
        guard !closed, let connection else { return }
        let body: [String: Any] = [
            "args": ["subscribe"] + events, "stdin": "",
            "windowId": NSNull(), "workspace": NSNull(),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        sendFrame(payload, on: connection)
        readEvents(onEvent)
    }

    private func readEvents(_ onEvent: @escaping ([String: Any]) -> Void) {
        receiveFrame { [weak self] data in
            guard let self, !self.closed else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["_event"] != nil else {
                self.fail("event stream broken")
                return
            }
            onEvent(json)
            self.readEvents(onEvent)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeoutWork?.cancel()
        timeoutWork = nil
        let unanswered = (inFlight.map { [$0] } ?? []) + pending
        inFlight = nil
        pending = []
        for request in unanswered {
            request.completion(.failure(.failed("connection closed")))
        }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        let handler = onClosed
        close()
        handler?("\(label): \(reason)")
    }

    // MARK: - framing

    private func sendFrame(_ payload: Data, on connection: NWConnection) {
        var count = UInt32(payload.count)
        var frame = Data(bytes: &count, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.fail("send: \(error)")
            }
        })
    }

    private func receiveFrame(_ completion: @escaping (Data?) -> Void) {
        receiveExact(4) { [weak self] header in
            guard let self, !self.closed else { return }
            guard let header else {
                completion(nil)
                return
            }
            // loadUnaligned: NWConnection may hand back a slice of its
            // internal buffer at an arbitrary byte offset.
            let count = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            // A frame beyond a few MB means the stream is out of sync (the
            // largest real payload is a full window list).
            guard count > 0, count < 4_000_000 else {
                completion(nil)
                return
            }
            self.receiveExact(Int(count), completion)
        }
    }

    private func receiveExact(_ length: Int, _ completion: @escaping (Data?) -> Void) {
        guard let connection else {
            completion(nil)
            return
        }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
            guard error == nil, let data, data.count == length else {
                completion(nil)
                return
            }
            completion(data)
        }
    }
}

struct AeroSpaceAnswer {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let serverVersion: String
}
