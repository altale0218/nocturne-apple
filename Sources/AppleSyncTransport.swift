import CryptoKit
import Foundation
import Network
import Security

/// An iPhone initiator for the existing Android secure transport. Album commands are sent after pairing and proof of possession.
enum AppleSyncTransport {
    static let port = NWEndpoint.Port(rawValue: 48773)!
    static let frameLimit = 1_048_576
    static let sessionLimit: UInt64 = 128 * 1024 * 1024 * 1024

    enum Failure: Error {
        case address, certificate, timeout, malformed, declined, changedPeer, authentication, closed
        case rejected(String)
    }

    struct Identity {
        let id: String
        let name: String
        let pin: String

        init(id: String, name: String, pin: String) throws {
            guard AppleSyncTransport.isHex(id, length: 32), AppleSyncTransport.isHex(pin, length: 64),
                  !name.isEmpty, name.utf16.count <= 80,
                  name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
                  else { throw Failure.malformed }
            self.id = id
            self.name = name
            self.pin = pin
        }
    }

    struct Peer {
        let identity: Identity
        let key: Data
        let address: String
    }

    static func connect(address: String, pin: String?, timeout: Int = 8) async throws -> Connection {
        let connection = try Connection(address: address, pin: pin)
        do { try await connection.start(timeout: timeout); return connection }
        catch { connection.cancel(); throw error }
    }

    static func probe(address: String) async throws -> Identity {
        let socket = try await connect(address: address, pin: nil)
        defer { socket.cancel() }
        try await socket.writeControl(["op": "probe173"])
        let reply = try await socket.readControl("probe173")
        let identity = try identity(reply)
        guard reply["platform195"] as? String == "android",
              identity.pin == socket.serverPin else { throw Failure.certificate }
        guard reply["mobileAlbum1"] as? Bool == true else { throw Failure.rejected("album-version") }
        return identity
    }

    static func pair(address: String, remote: Identity, local: Identity,
                     confirm: (String, String) async -> Bool,
                     store: (Peer, Bool) throws -> Void) async throws -> Peer {
        guard local.id != remote.id else { throw Failure.changedPeer }
        let socket = try await connect(address: address, pin: remote.pin)
        defer { socket.cancel() }
        let nonce = try AuthenticatedCipher.random(32).base64EncodedString()
        try await socket.writeControl(["op": "pair173", "id": local.id, "name": local.name,
                                       "pin": local.pin, "commit": hash(nonce)])
        let challenge = try await socket.readControl("commit173")
        let actual = try identity(challenge)
        guard actual.id == remote.id, actual.pin == remote.pin, actual.pin == socket.serverPin,
              let serverNonce = challenge["nonce"] as? String else { throw Failure.changedPeer }
        _ = try decode(serverNonce, count: 32)
        try await socket.writeControl(["op": "reveal173", "nonce": nonce])
        _ = try await socket.readControl("compare173")
        let transcript = "Nocturne/Sync173/pair|\(local.pin)|\(remote.pin)|\(local.id)|\(remote.id)|\(nonce)|\(serverNonce)"
        guard await confirm(actual.name, comparison(transcript)) else { throw Failure.declined }
        try await socket.writeControl(["op": "confirm173", "proof": hash("confirm|" + transcript)])
        let paired = try await socket.readControl("paired173")
        guard paired["id"] as? String == remote.id, paired["pin"] as? String == remote.pin,
              let encodedKey = paired["key"] as? String else { throw Failure.changedPeer }
        let peer = Peer(identity: actual, key: try decode(encodedKey, count: 32), address: address)
        try store(peer, false)
        try await socket.writeControl(["op": "stored173", "proof": mac(peer.key, "stored|" + transcript).base64EncodedString()])
        let verified = try await socket.readControl("trusted173")
        try checkMAC(verified["proof"], key: peer.key, transcript: "trusted|" + transcript)
        try store(peer, true)
        return peer
    }

    // Only a transfer with an already approved scope may call this path. Each
    // attempt uses the same address and certificate pin, before the peer proof.
    private static func reconnect(_ peer: Peer) async throws -> Connection {
        let delays: [UInt64] = [0, 450_000_000, 900_000_000]
        for (attempt, delay) in delays.enumerated() {
            try Task.checkCancellation()
            if delay != 0 { try await Task.sleep(nanoseconds: delay) }
            do {
                return try await connect(address: peer.address, pin: peer.identity.pin, timeout: 2)
            } catch {
                try Task.checkCancellation()
                guard attempt < delays.count - 1, retryableConnectionLoss(error) else { throw error }
            }
        }
        throw Failure.timeout
    }

    static func retryableConnectionLoss(_ error: Error) -> Bool {
        switch error {
        case Failure.closed, Failure.timeout: return true
        case let NWError.posix(code):
            return [.ECONNABORTED, .ECONNRESET, .ECONNREFUSED, .ENOTCONN,
                    .EHOSTUNREACH, .ENETDOWN, .ENETUNREACH, .ETIMEDOUT].contains(code)
        default: return false
        }
    }

    static func authenticate(_ peer: Peer, local: Identity, resuming: Bool = false) async throws -> Channel {
        let socket: Connection
        if resuming { socket = try await reconnect(peer) }
        else { socket = try await connect(address: peer.address, pin: peer.identity.pin) }
        do {
            let privateKey = P384.KeyAgreement.PrivateKey()
            let point = privateKey.publicKey.x963Representation.base64EncodedString()
            let nonce = try AuthenticatedCipher.random(32).base64EncodedString()
            let mode = "ordinary", cause = "manual"
            let client = "Nocturne/Sync173/client|\(local.id)|\(peer.identity.id)|\(mode)|\(cause)|\(nonce)|\(point)"
            try await socket.writeControl(["op": "hello173", "id": local.id, "mode": mode, "cause": cause,
                                           "nonce": nonce, "point": point, "proof": mac(peer.key, client).base64EncodedString()])
            let response = try await socket.readControl("hello-ack173")
            guard response["id"] as? String == peer.identity.id, response["mode"] as? String == mode,
                  let serverNonce = response["nonce"] as? String, let serverPoint = response["point"] as? String
                  else { throw Failure.authentication }
            _ = try decode(serverNonce, count: 32)
            let transcript = "Nocturne/Sync173/server|\(client)|\(serverNonce)|\(serverPoint)|\(mode)"
            try checkMAC(response["proof"], key: peer.key, transcript: transcript)
            let publicKey = try P384.KeyAgreement.PublicKey(x963Representation: decode(serverPoint, count: 97))
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let shared = secret.withUnsafeBytes { Data(SHA384.hash(data: Data($0))) }
            let salt = Data(SHA384.hash(data: Data((nonce + "|" + serverNonce).utf8)))
            let context = Data(SHA256.hash(data: Data(transcript.utf8)))
            let channel = Channel(socket: socket, cipher: try Cipher(shared: shared, salt: salt, context: context))
            let ready = Data("ready173".utf8)
            try await channel.send(8, ready)
            let result = try await channel.receiveRaw()
            guard result.kind == 8, result.data == ready else { throw Failure.authentication }
            return channel
        } catch {
            socket.cancel()
            throw error
        }
    }

    private static func identity(_ value: [String: Any]) throws -> Identity {
        guard let id = value["id"] as? String, let name = value["name"] as? String,
              let pin = value["pin"] as? String else { throw Failure.malformed }
        return try Identity(id: id, name: name, pin: pin)
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func decode(_ value: String, count: Int) throws -> Data {
        guard value.utf8.count == ((count + 2) / 3) * 4, let bytes = Data(base64Encoded: value),
              bytes.count == count, bytes.base64EncodedString() == value else { throw Failure.malformed }
        return bytes
    }

    private static func mac(_ key: Data, _ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }

    private static func checkMAC(_ value: Any?, key: Data, transcript: String) throws {
        guard let text = value as? String else { throw Failure.authentication }
        let proof = try decode(text, count: 32)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(transcript.utf8),
                                                    using: SymmetricKey(data: key))
              else { throw Failure.authentication }
    }

    static func hash(_ value: String) -> String { hex(Data(SHA256.hash(data: Data(value.utf8)))) }

    static func hex(_ data: Data) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(data.count * 2)
        for byte in data { result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 15)]) }
        return String(decoding: result, as: UTF8.self)
    }

    static func comparison(_ value: String) -> String {
        let number = SHA256.hash(data: Data(value.utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let raw = String(number % 1_000_000)
        return String(repeating: "0", count: 6 - raw.count) + raw
    }

    static func localIPv4(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        let bytes: [UInt8] = pieces.compactMap {
            guard !$0.isEmpty, $0.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt8($0), String(number) == $0 else { return nil }
            return number
        }
        guard pieces.count == 4, bytes.count == 4, bytes[3] != 0, bytes[3] != 255 else { return false }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 192 && bytes[1] == 168)
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var network = value.bigEndian
        return withUnsafeBytes(of: &network) { Data($0) }
    }

    private static func number<T: FixedWidthInteger>(_ bytes: Data, _: T.Type) -> T {
        bytes.reduce(T(0)) { ($0 << 8) | T($1) }
    }

    private static func decodeObject(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
        return value
    }

    struct Cipher {
        private let context: Data
        private let tx: SymmetricKey
        private let rx: SymmetricKey
        private let txPrefix: Data
        private let rxPrefix: Data

        init(shared: Data, salt: Data, context: Data) throws {
            guard shared.count == 48, salt.count == 48, context.count == 32 else { throw Failure.malformed }
            self.context = context
            let key = HKDF<SHA384>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared), salt: salt,
                                             info: context, outputByteCount: 72)
            let material = key.withUnsafeBytes { Data($0) }
            tx = SymmetricKey(data: material[0..<32])
            rx = SymmetricKey(data: material[32..<64])
            txPrefix = Data(material[64..<68])
            rxPrefix = Data(material[68..<72])
        }

        struct Header { let kind: UInt8; let length: Int }

        static func parse(_ header: Data, sequence: UInt64) throws -> Header {
            guard header.count == 13, let kind = header.first, (1...8).contains(kind),
                  number(Data(header.dropFirst().prefix(8)), UInt64.self) == sequence,
                  sequence < UInt64(Int64.max)
                  else { throw Failure.malformed }
            let length = Int(number(Data(header.suffix(4)), UInt32.self))
            guard length <= frameLimit else { throw Failure.malformed }
            return Header(kind: kind, length: length)
        }

        func seal(_ plaintext: Data, kind: UInt8, sequence: UInt64) throws -> Data {
            guard (1...8).contains(kind), plaintext.count <= frameLimit, sequence < UInt64(Int64.max)
                  else { throw Failure.malformed }
            let header = Data([kind]) + bytes(sequence) + bytes(UInt32(plaintext.count))
            let nonce = try AES.GCM.Nonce(data: txPrefix + bytes(sequence))
            let encrypted = try AES.GCM.seal(plaintext, using: tx, nonce: nonce,
                                             authenticating: context + Data([0]) + header)
            return header + encrypted.ciphertext + encrypted.tag
        }

        func open(_ encoded: Data, header: Data, sequence: UInt64) throws -> Data {
            let value = try Self.parse(header, sequence: sequence)
            guard encoded.count == value.length + 16 else { throw Failure.malformed }
            let nonce = try AES.GCM.Nonce(data: rxPrefix + bytes(sequence))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encoded.prefix(value.length), tag: encoded.suffix(16))
            return try AES.GCM.open(box, using: rx, authenticating: context + Data([1]) + header)
        }
    }

    actor Channel {
        private let socket: Connection
        private let cipher: Cipher
        private var transmitted: UInt64 = 0, received: UInt64 = 0, txBytes: UInt64 = 0, rxBytes: UInt64 = 0
        private var sending = false, reading = false

        init(socket: Connection, cipher: Cipher) { self.socket = socket; self.cipher = cipher }

        func send(_ kind: UInt8, _ data: Data) async throws {
            try await sendFrame(kind, data, cancelledTaskClosesSocket: true)
        }

        func sendWaiting() async throws {
            guard !Task.isCancelled else { return }
            try await sendFrame(8, Data("waiting173".utf8), cancelledTaskClosesSocket: false)
        }

        private func sendFrame(_ kind: UInt8, _ data: Data, cancelledTaskClosesSocket: Bool) async throws {
            guard !sending, UInt64(data.count) <= sessionLimit - txBytes else { throw Failure.malformed }
            sending = true
            defer { sending = false }
            do {
                let frame = try cipher.seal(data, kind: kind, sequence: transmitted)
                try await socket.send(frame, cancelledTaskClosesSocket: cancelledTaskClosesSocket)
                transmitted += 1
                txBytes += UInt64(data.count)
            } catch { socket.cancel(); throw error }
        }

        func receiveRaw() async throws -> (kind: UInt8, data: Data) {
            guard !reading else { throw Failure.malformed }
            reading = true
            defer { reading = false }
            do {
                let header = try await socket.receive(13)
                let value = try Cipher.parse(header, sequence: received)
                guard UInt64(value.length) <= sessionLimit - rxBytes else { throw Failure.malformed }
                let encoded = try await socket.receive(value.length + 16)
                let data = try cipher.open(encoded, header: header, sequence: received)
                received += 1
                rxBytes += UInt64(data.count)
                return (value.kind, data)
            } catch { socket.cancel(); throw error }
        }

        func receiveFrame() async throws -> (kind: UInt8, data: Data) {
            for _ in 0..<180 {
                let result = try await receiveRaw()
                if result.kind != 8 { return result }
                guard result.data == Data("waiting173".utf8) else { throw Failure.malformed }
            }
            socket.cancel()
            throw Failure.timeout
        }

        func sendObject(_ kind: UInt8, _ value: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard data.count <= 900_000 else { throw Failure.malformed }
            try await send(kind, data)
        }

        func receiveObject(_ kind: UInt8) async throws -> [String: Any] {
            let result = try await receiveFrame()
            guard result.kind == kind, result.data.count <= 900_000 else { throw Failure.malformed }
            return try decodeObject(result.data)
        }

        func close() { socket.cancel() }
    }

    static func verifiedPeerPin(_ certificates: [SecCertificate], expected: String?) -> String? {
        guard (1...2).contains(certificates.count), let leaf = certificates.first,
              SecCertificateCopySubjectSummary(leaf) as String? == "Nocturne LAN Sync 173",
              let transport = try? AndroidAlbumCertificate(SecCertificateCopyData(leaf) as Data) else { return nil }
        let root: SecCertificate
        if let encodedIdentity = transport.extensions[AndroidAlbumCertificate.identityExtension] {
            guard let identity = SecCertificateCreateWithData(nil, encodedIdentity as CFData),
                  SecCertificateCopySubjectSummary(identity) as String? == "Nocturne LAN Sync 173",
                  certificates.count == 1 || SecCertificateCopyData(certificates[1]) as Data == encodedIdentity,
                  let parsed = try? AndroidAlbumCertificate(encodedIdentity),
                  let identityKey = SecCertificateCopyKey(identity), let transportKey = SecCertificateCopyKey(leaf),
                  AndroidAlbumCertificate.isKey(identityKey, type: kSecAttrKeyTypeRSA, bits: 3072...8192),
                  AndroidAlbumCertificate.isKey(transportKey, type: kSecAttrKeyTypeECSECPrimeRandom, bits: 256...256),
                  parsed.subject == parsed.issuer, transport.issuer == parsed.subject, transport.subject == parsed.subject,
                  transport.notBefore >= parsed.notBefore, transport.notAfter <= parsed.notAfter,
                  parsed.valid(at: Date()), transport.valid(at: Date()),
                  transport.isDelegatedServer, transport.algorithm == .rsaSignatureMessagePKCS1v15SHA256,
                  parsed.verifies(using: identityKey), transport.verifies(using: identityKey) else { return nil }
            root = identity
        } else {
            // A legacy single-certificate endpoint still needs normal Security trust evaluation.
            guard certificates.count == 1 else { return nil }
            var candidate: SecTrust?
            guard SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &candidate) == errSecSuccess,
                  let trust = candidate,
                  SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                  SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
                  SecTrustEvaluateWithError(trust, nil) else { return nil }
            root = leaf
        }
        let actual = hex(Data(SHA256.hash(data: SecCertificateCopyData(root) as Data)))
        return expected == nil || actual == expected ? actual : nil
    }

    final class Connection {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "com.nocturne.album-sync.socket")
        private let tlsState: PeerCertificate

        var serverPin: String? { tlsState.read() }

        init(address: String, pin: String?) throws {
            guard AppleSyncTransport.localIPv4(address), let ip = IPv4Address(address) else { throw Failure.address }
            if let pin = pin, !AppleSyncTransport.isHex(pin, length: 64) { throw Failure.certificate }
            let certificate = PeerCertificate()
            tlsState = certificate
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, suppliedTrust, complete in
                var chain: [SecCertificate] = []
                let accessible = sec_protocol_metadata_access_peer_certificate_chain(metadata) { remote in
                    if chain.count < 3 { chain.append(sec_certificate_copy_ref(remote).takeRetainedValue()) }
                }
                if !accessible || chain.isEmpty {
                    let trust = sec_trust_copy_ref(suppliedTrust).takeRetainedValue()
                    guard SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { complete(false); return }
                    chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
                }
                guard let actual = AppleSyncTransport.verifiedPeerPin(chain, expected: pin)
                      else { complete(false); return }
                certificate.set(actual)
                complete(true)
            }, queue)
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: tls, tcp: tcp)
            parameters.prohibitedInterfaceTypes = [.cellular, .other, .loopback]
            connection = NWConnection(host: .ipv4(ip), port: AppleSyncTransport.port, using: parameters)
        }

        func start(timeout: Int = 8) async throws {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    queue.async {
                        let deadline = DispatchWorkItem { self.connection.cancel() }
                        self.connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                deadline.cancel()
                                self.connection.stateUpdateHandler = nil
                                continuation.resume()
                            case .failed(let error):
                                deadline.cancel()
                                self.connection.stateUpdateHandler = nil
                                continuation.resume(throwing: error)
                            case .cancelled:
                                deadline.cancel()
                                self.connection.stateUpdateHandler = nil
                                continuation.resume(throwing: Failure.closed)
                            default: break
                            }
                        }
                        self.queue.asyncAfter(deadline: .now() + .seconds(timeout), execute: deadline)
                        self.connection.start(queue: self.queue)
                    }
                }
            }, onCancel: { self.cancel() })
        }

        func send(_ data: Data, cancelledTaskClosesSocket: Bool = true) async throws {
            let transmit = {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let deadline = DispatchWorkItem { self.connection.cancel() }
                    self.queue.asyncAfter(deadline: .now() + .seconds(30), execute: deadline)
                    self.connection.send(content: data, completion: .contentProcessed { error in
                        deadline.cancel()
                        if let error = error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                }
            }
            if cancelledTaskClosesSocket {
                try await withTaskCancellationHandler(operation: {
                    try Task.checkCancellation()
                    try await transmit()
                }, onCancel: { self.cancel() })
            } else {
                try await transmit()
            }
        }

        func receive(_ count: Int, timeout: Int = 30) async throws -> Data {
            guard count > 0, count <= frameLimit + 16 else { throw Failure.malformed }
            return try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let deadline = DispatchWorkItem { self.connection.cancel() }
                    queue.asyncAfter(deadline: .now() + .seconds(timeout), execute: deadline)
                    connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                        deadline.cancel()
                        if let error = error { continuation.resume(throwing: error) }
                        else if let data = data, data.count == count { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: Failure.closed) }
                    }
                }
            }, onCancel: { self.cancel() })
        }

        func writeControl(_ value: [String: Any]) async throws {
            var value = value
            value["schema"] = 173
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard data.count <= 16_384 else { throw Failure.malformed }
            try await send(bytes(UInt32(data.count)) + data)
        }

        func readControl(_ operation: String) async throws -> [String: Any] {
            let count = Int(number(try await receive(4, timeout: 150), UInt32.self))
            guard (2...16_384).contains(count) else { throw Failure.malformed }
            let value = try decodeObject(try await receive(count))
            guard value["schema"] as? Int == 173 else { throw Failure.malformed }
            if let rejected = value["error"] as? String,
               ["mode173", "consent173", "automatic173"].contains(rejected) {
                throw Failure.rejected(rejected)
            }
            guard value["op"] as? String == operation else { throw Failure.malformed }
            return value
        }

        func cancel() { connection.cancel() }
    }

    private final class PeerCertificate {
        private let lock = NSLock()
        private var pin: String?
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return pin }
        func set(_ value: String) { lock.lock(); defer { lock.unlock() }; pin = value }
    }
}

/// The Android Keystore root proves device identity and does not assert CA authority.
private struct AndroidAlbumCertificate {
    static let identityExtension = Data([0x2b, 0x06, 0x01, 0x04, 0x01, 0x83, 0xbf, 0x30, 0x01, 0x81, 0x35])
    private static let constraints = Data([0x55, 0x1d, 0x13])
    private static let keyUsage = Data([0x55, 0x1d, 0x0f])
    private static let extendedUsage = Data([0x55, 0x1d, 0x25])
    private static let serverUsage = Data([0x30, 0x0a, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
    private static let signatureOIDPrefix: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01]

    let subject: Data
    let issuer: Data
    let notBefore: Date
    let notAfter: Date
    let algorithm: SecKeyAlgorithm
    let extensions: [Data: Data]
    private let signed: Data
    private let signature: Data
    private let critical: Set<Data>

    var isDelegatedServer: Bool {
        critical == [Self.constraints, Self.keyUsage] &&
            extensions[Self.constraints] == Data([0x30, 0x00]) &&
            extensions[Self.keyUsage] == Data([0x03, 0x02, 0x07, 0x80]) &&
            extensions[Self.extendedUsage] == Self.serverUsage
    }

    init(_ data: Data) throws {
        guard (128...32_768).contains(data.count) else { throw AppleSyncTransport.Failure.certificate }
        let bytes = Array(data)
        var entry = Reader(bytes, from: bytes.indices)
        var certificate = try entry.reader(0x30)
        guard entry.complete else { throw AppleSyncTransport.Failure.certificate }
        let envelope = try certificate.read(0x30)
        signed = Data(bytes[envelope.encoded])
        var tbs = Reader(bytes, from: envelope.value)
        let outerAlgorithm = try certificate.read(0x30)
        algorithm = try Self.signatureAlgorithm(Reader(bytes, from: outerAlgorithm.value))
        let bits = try certificate.read(0x03)
        guard certificate.complete, bits.value.count > 1, bytes[bits.value.lowerBound] == 0
              else { throw AppleSyncTransport.Failure.certificate }
        signature = Data(bytes[(bits.value.lowerBound + 1)..<bits.value.upperBound])

        if tbs.next == 0xa0 {
            var version = try tbs.reader(0xa0)
            let identifier = try version.read(0x02)
            guard version.complete, identifier.value.count == 1, bytes[identifier.value.lowerBound] <= 2
                  else { throw AppleSyncTransport.Failure.certificate }
        }
        let serial = try tbs.read(0x02)
        let innerAlgorithm = try tbs.read(0x30)
        guard (1...21).contains(serial.value.count), bytes[outerAlgorithm.encoded].elementsEqual(bytes[innerAlgorithm.encoded])
              else { throw AppleSyncTransport.Failure.certificate }
        issuer = Data(bytes[(try tbs.read(0x30)).encoded])
        var validity = try tbs.reader(0x30)
        notBefore = try Self.date(validity.read())
        notAfter = try Self.date(validity.read())
        guard validity.complete, notBefore < notAfter else { throw AppleSyncTransport.Failure.certificate }
        subject = Data(bytes[(try tbs.read(0x30)).encoded])
        _ = try tbs.read(0x30) // SubjectPublicKeyInfo, validated by Security.framework.

        if tbs.next == 0x81 { _ = try tbs.read(0x81) }
        if tbs.next == 0x82 { _ = try tbs.read(0x82) }
        var fields: [Data: Data] = [:]
        var criticalFields: Set<Data> = []
        if tbs.next == 0xa3 {
            var wrapper = try tbs.reader(0xa3)
            var sequence = try wrapper.reader(0x30)
            guard wrapper.complete else { throw AppleSyncTransport.Failure.certificate }
            while !sequence.complete {
                guard fields.count < 24 else { throw AppleSyncTransport.Failure.certificate }
                var field = try sequence.reader(0x30)
                let oid = Data(bytes[(try field.read(0x06)).value])
                guard !oid.isEmpty, oid.count <= 32, fields[oid] == nil else { throw AppleSyncTransport.Failure.certificate }
                if field.next == 0x01 {
                    let flag = try field.read(0x01)
                    guard flag.value.count == 1, bytes[flag.value.lowerBound] == 0xff else { throw AppleSyncTransport.Failure.certificate }
                    criticalFields.insert(oid)
                }
                let body = try field.read(0x04)
                guard field.complete else { throw AppleSyncTransport.Failure.certificate }
                fields[oid] = Data(bytes[body.value])
            }
        }
        guard tbs.complete else { throw AppleSyncTransport.Failure.certificate }
        extensions = fields
        critical = criticalFields
    }

    func valid(at date: Date) -> Bool { notBefore <= date && date <= notAfter }
    func verifies(using key: SecKey) -> Bool {
        SecKeyIsAlgorithmSupported(key, .verify, algorithm) &&
            SecKeyVerifySignature(key, algorithm, signed as CFData, signature as CFData, nil)
    }

    static func isKey(_ key: SecKey, type: CFString, bits: ClosedRange<Int>) -> Bool {
        guard let values = SecKeyCopyAttributes(key) as? [String: Any],
              let kind = values[kSecAttrKeyType as String] as? String,
              let width = values[kSecAttrKeySizeInBits as String] as? Int else { return false }
        return kind == type as String && bits.contains(width)
    }

    private static func signatureAlgorithm(_ container: Reader) throws -> SecKeyAlgorithm {
        var reader = container
        let oid = try reader.read(0x06)
        if !reader.complete {
            let empty = try reader.read(0x05)
            guard empty.value.isEmpty else { throw AppleSyncTransport.Failure.certificate }
        }
        let bytes = reader.bytes[oid.value]
        guard reader.complete, bytes.count == 9, bytes.dropLast().elementsEqual(signatureOIDPrefix) else {
            throw AppleSyncTransport.Failure.certificate
        }
        switch bytes.last {
        case 11: return .rsaSignatureMessagePKCS1v15SHA256
        case 12: return .rsaSignatureMessagePKCS1v15SHA384
        case 13: return .rsaSignatureMessagePKCS1v15SHA512
        default: throw AppleSyncTransport.Failure.certificate
        }
    }

    private static func date(_ field: Reader.Field) throws -> Date {
        guard let text = String(bytes: field.bytes[field.value], encoding: .ascii), text.last == "Z"
              else { throw AppleSyncTransport.Failure.certificate }
        let time: String
        if field.tag == 0x17, text.utf8.count == 13, let part = Int(text.prefix(2)) {
            time = (part >= 50 ? "19" : "20") + text
        } else if field.tag == 0x18, text.utf8.count == 15 { time = text }
        else { throw AppleSyncTransport.Failure.certificate }
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyyMMddHHmmss'Z'"
        parser.isLenient = false
        guard let date = parser.date(from: time), parser.string(from: date) == time else {
            throw AppleSyncTransport.Failure.certificate
        }
        return date
    }

    private struct Reader {
        struct Field {
            let bytes: [UInt8]
            let tag: UInt8
            let encoded: Range<Int>
            let value: Range<Int>
        }
        let bytes: [UInt8]
        let end: Int
        var at: Int
        var complete: Bool { at == end }
        var next: UInt8? { at < end ? bytes[at] : nil }

        init(_ bytes: [UInt8], from range: Range<Int>) { self.bytes = bytes; at = range.lowerBound; end = range.upperBound }

        mutating func reader(_ tag: UInt8) throws -> Reader { Reader(bytes, from: try read(tag).value) }

        mutating func read(_ expected: UInt8? = nil) throws -> Field {
            let start = at
            guard end - at >= 2 else { throw AppleSyncTransport.Failure.certificate }
            let tag = bytes[at], first = Int(bytes[at + 1])
            guard tag & 0x1f != 0x1f, expected == nil || tag == expected else { throw AppleSyncTransport.Failure.certificate }
            at += 2
            var length = first
            if first >= 128 {
                let octets = first & 127
                guard (1...2).contains(octets), octets <= end - at, bytes[at] != 0 else {
                    throw AppleSyncTransport.Failure.certificate
                }
                length = 0
                for _ in 0..<octets { length = (length << 8) | Int(bytes[at]); at += 1 }
                guard length >= 128 else { throw AppleSyncTransport.Failure.certificate }
            }
            guard length <= end - at else { throw AppleSyncTransport.Failure.certificate }
            let value = at..<(at + length)
            at += length
            return Field(bytes: bytes, tag: tag, encoded: start..<at, value: value)
        }
    }
}
