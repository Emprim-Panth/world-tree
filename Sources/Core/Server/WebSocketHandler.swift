import Foundation
import Network
import CommonCrypto

// MARK: - WebSocket Frame Types

/// RFC 6455 opcodes
enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text         = 0x1
    case binary       = 0x2
    // 0x3-0x7 reserved
    case close        = 0x8
    case ping         = 0x9
    case pong         = 0xA
    // 0xB-0xF reserved

    var isControl: Bool { rawValue >= 0x8 }
}

/// A single decoded WebSocket frame.
struct WebSocketFrame {
    let fin: Bool
    let opcode: WebSocketOpcode
    let payload: Data

    /// Convenience: text payload (for text frames)
    var text: String? { String(data: payload, encoding: .utf8) }

    /// Close code (first 2 bytes of payload on close frames)
    var closeCode: UInt16? {
        guard opcode == .close, payload.count >= 2 else { return nil }
        return UInt16(payload[0]) << 8 | UInt16(payload[1])
    }

    /// Close reason (bytes after the 2-byte code on close frames)
    var closeReason: String? {
        guard opcode == .close, payload.count > 2 else { return nil }
        return String(data: payload[2...], encoding: .utf8)
    }
}

// MARK: - Frame Codec

/// Stateless RFC 6455 frame encoder/decoder.
enum WebSocketCodec {

    // MARK: Decode

    /// Attempt to decode one frame from the front of `buffer`.
    /// Returns `(frame, bytesConsumed)` on success, `nil` if not enough data.
    /// Throws on protocol violations (unmasked client frame, reserved bits, etc.).
    static func decode(from buffer: Data) throws -> (WebSocketFrame, Int)? {
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[buffer.startIndex]
        let byte1 = buffer[buffer.startIndex + 1]

        let fin = (byte0 & 0x80) != 0
        let rsv = byte0 & 0x70
        guard rsv == 0 else {
            throw WebSocketError.protocolViolation("RSV bits must be 0 (no extensions)")
        }

        guard let opcode = WebSocketOpcode(rawValue: byte0 & 0x0F) else {
            throw WebSocketError.protocolViolation("Unknown opcode: \(byte0 & 0x0F)")
        }

        let masked = (byte1 & 0x80) != 0
        // RFC 6455 Section 5.1: client frames MUST be masked
        guard masked else {
            throw WebSocketError.protocolViolation("Client frames must be masked")
        }

        var payloadLength = UInt64(byte1 & 0x7F)
        var offset = 2

        if payloadLength == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            payloadLength = UInt64(buffer[buffer.startIndex + offset]) << 8
                         | UInt64(buffer[buffer.startIndex + offset + 1])
            offset += 2
        } else if payloadLength == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = payloadLength << 8 | UInt64(buffer[buffer.startIndex + offset + i])
            }
            offset += 8
            // RFC 6455: most significant bit must be 0
            guard payloadLength & (1 << 63) == 0 else {
                throw WebSocketError.protocolViolation("Payload length MSB must be 0")
            }
        }

        // Control frames cannot exceed 125 bytes
        if opcode.isControl && payloadLength > 125 {
            throw WebSocketError.protocolViolation("Control frame payload exceeds 125 bytes")
        }

        // Control frames must not be fragmented
        if opcode.isControl && !fin {
            throw WebSocketError.protocolViolation("Control frames must not be fragmented")
        }

        // Mask key (4 bytes, present when masked)
        guard buffer.count >= offset + 4 else { return nil }
        let maskKey = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + 4)])
        offset += 4

        // Payload
        let totalNeeded = offset + Int(payloadLength)
        guard buffer.count >= totalNeeded else { return nil }

        var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + totalNeeded)])

        // Unmask
        for i in 0..<payload.count {
            payload[i] ^= maskKey[i % 4]
        }

        let frame = WebSocketFrame(fin: fin, opcode: opcode, payload: payload)
        return (frame, totalNeeded)
    }

    // MARK: Encode

    /// Encode a frame to send from server to client.
    /// Server frames are NOT masked (RFC 6455 Section 5.1).
    static func encode(_ frame: WebSocketFrame) -> Data {
        var data = Data()

        // Byte 0: FIN + opcode
        var byte0: UInt8 = frame.opcode.rawValue
        if frame.fin { byte0 |= 0x80 }
        data.append(byte0)

        // Byte 1: no mask + payload length
        let length = frame.payload.count
        if length < 126 {
            data.append(UInt8(length))
        } else if length <= 0xFFFF {
            data.append(126)
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8(length & 0xFF))
        } else {
            data.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((length >> i) & 0xFF))
            }
        }

        data.append(frame.payload)
        return data
    }

    /// Convenience: encode a text frame.
    static func textFrame(_ text: String) -> Data {
        encode(WebSocketFrame(fin: true, opcode: .text, payload: Data(text.utf8)))
    }

    /// Convenience: encode a ping frame.
    static func pingFrame(payload: Data = Data()) -> Data {
        encode(WebSocketFrame(fin: true, opcode: .ping, payload: payload))
    }

    /// Convenience: encode a pong frame.
    static func pongFrame(payload: Data = Data()) -> Data {
        encode(WebSocketFrame(fin: true, opcode: .pong, payload: payload))
    }

    /// Convenience: encode a close frame.
    static func closeFrame(code: UInt16 = 1000, reason: String? = nil) -> Data {
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        if let reason, let reasonData = reason.data(using: .utf8) {
            payload.append(reasonData)
        }
        return encode(WebSocketFrame(fin: true, opcode: .close, payload: payload))
    }

    // MARK: - Handshake

    /// Compute the `Sec-WebSocket-Accept` header value for the given client key.
    /// SHA-1(key + "258EAFA5-E914-47DA-95CA-5AB9DB81F65E") → base64
    static func acceptKey(for clientKey: String) -> String {
        // RFC 6455 §1.3 magic GUID as explicit byte literals — no string encoding can corrupt these.
        let magic: [UInt8] = [
            0x32,0x35,0x38,0x45,0x41,0x46,0x41,0x35, // 258EAFA5
            0x2D,                                       // -
            0x45,0x39,0x31,0x34,                       // E914
            0x2D,                                       // -
            0x34,0x37,0x44,0x41,                       // 47DA
            0x2D,                                       // -
            0x39,0x35,0x43,0x41,                       // 95CA
            0x2D,                                       // -
            0x35,0x41,0x42,0x39,0x44,0x42,0x38,0x31,  // 5AB9DB81
            0x46,0x36,0x35,0x45                        // F65E
        ]
        var combined = [UInt8](clientKey.utf8) + magic
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(&combined, CC_LONG(combined.count), &digest)
        return Data(digest).base64EncodedString()
    }

    /// Build the HTTP 101 Switching Protocols response.
    static func upgradeResponse(for clientKey: String) -> Data {
        let accept = acceptKey(for: clientKey)
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: WebSocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        return Data(response.utf8)
    }
}

// MARK: - WebSocket Errors

enum WebSocketError: Error, LocalizedError {
    case protocolViolation(String)
    case connectionClosed
    case messageTooLarge
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .protocolViolation(let msg): return "WebSocket protocol violation: \(msg)"
        case .connectionClosed: return "WebSocket connection closed"
        case .messageTooLarge: return "WebSocket message too large"
        case .invalidUTF8: return "Invalid UTF-8 in text frame"
        }
    }
}

// MARK: - WebSocketConnection

/// Wraps an NWConnection that has been upgraded to WebSocket mode.
/// Handles frame-level reading, fragment reassembly, and sending.
final class WebSocketConnection: @unchecked Sendable {
    let id: String
    let connection: NWConnection

    /// Callback for received complete text messages (after fragment reassembly).
    var onMessage: (@Sendable (String) -> Void)?
    /// Callback for connection close (code, reason).
    var onClose: (@Sendable (UInt16, String?) -> Void)?
    /// Callback for pong received.
    var onPong: (@Sendable () -> Void)?

    private var buffer = Data()
    private var fragmentBuffer = Data()
    private var fragmentOpcode: WebSocketOpcode?
    private let lock = NSLock()
    private var isClosed = false

    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }

    // MARK: - Reading

    /// Start the read loop. Call once after upgrade.
    func startReading() {
        readNextChunk()
    }

    private func readNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                canvasLog("[WebSocket:\(self.id)] Read error: \(error)")
                self.handleClose(code: 1006, reason: nil)
                return
            }

            if let data {
                self.lock.lock()
                self.buffer.append(data)
                self.lock.unlock()
                self.processBuffer()
            }

            if isComplete {
                self.handleClose(code: 1006, reason: nil)
            } else {
                self.readNextChunk()
            }
        }
    }

    private func processBuffer() {
        lock.lock()
        defer { lock.unlock() }

        while true {
            do {
                guard let (frame, consumed) = try WebSocketCodec.decode(from: buffer) else {
                    break // Need more data
                }
                buffer.removeFirst(consumed)
                handleFrame(frame)
            } catch {
                canvasLog("[WebSocket:\(id)] Frame error: \(error)")
                sendCloseAndDisconnect(code: 1002, reason: error.localizedDescription)
                break
            }
        }
    }

    private func handleFrame(_ frame: WebSocketFrame) {
        switch frame.opcode {
        case .text, .binary:
            if frame.fin {
                // Complete single-frame message
                if fragmentOpcode != nil {
                    // We were in the middle of a fragmented message — protocol error
                    canvasLog("[WebSocket:\(id)] New data frame while fragments pending")
                    sendCloseAndDisconnect(code: 1002, reason: "Unexpected data frame during fragmentation")
                    return
                }
                if frame.opcode == .text {
                    guard let text = frame.text else {
                        sendCloseAndDisconnect(code: 1007, reason: "Invalid UTF-8")
                        return
                    }
                    onMessage?(text)
                }
                // Binary frames ignored for v1
            } else {
                // Start of fragmented message
                fragmentOpcode = frame.opcode
                fragmentBuffer = frame.payload
            }

        case .continuation:
            guard fragmentOpcode != nil else {
                sendCloseAndDisconnect(code: 1002, reason: "Unexpected continuation frame")
                return
            }
            fragmentBuffer.append(frame.payload)
            if frame.fin {
                // Fragment complete
                let opcode = fragmentOpcode!
                let assembled = fragmentBuffer
                fragmentOpcode = nil
                fragmentBuffer = Data()

                if opcode == .text {
                    guard let text = String(data: assembled, encoding: .utf8) else {
                        sendCloseAndDisconnect(code: 1007, reason: "Invalid UTF-8")
                        return
                    }
                    onMessage?(text)
                }
                // Binary ignored for v1
            }

        case .ping:
            // Respond with pong echoing the same payload
            let pong = WebSocketCodec.pongFrame(payload: frame.payload)
            connection.send(content: pong, completion: .idempotent)

        case .pong:
            onPong?()

        case .close:
            let code = frame.closeCode ?? 1000
            let reason = frame.closeReason
            // Echo close frame back per RFC 6455
            let closeData = WebSocketCodec.closeFrame(code: code, reason: reason)
            connection.send(content: closeData, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            onClose?(code, reason)
        }
    }

    // MARK: - Sending

    /// Send a text message over the WebSocket.
    func send(text: String) {
        guard !isClosed else { return }
        let data = WebSocketCodec.textFrame(text)
        connection.send(content: data, completion: .idempotent)
    }

    /// Send a ping frame.
    func sendPing() {
        guard !isClosed else { return }
        let data = WebSocketCodec.pingFrame()
        connection.send(content: data, completion: .idempotent)
    }

    /// Send a close frame and cancel the connection.
    func sendCloseAndDisconnect(code: UInt16 = 1000, reason: String? = nil) {
        guard !isClosed else { return }
        isClosed = true
        let data = WebSocketCodec.closeFrame(code: code, reason: reason)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
        onClose?(code, reason)
    }

    private func handleClose(code: UInt16, reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        onClose?(code, reason)
        connection.cancel()
    }
}

// MARK: - WSClientSendable

/// Unified send interface shared by WebSocketConnection (manual RFC 6455) and
/// NativeWebSocketConnection (NWProtocolWebSocket). Lets CanvasServer treat both identically.
protocol WSClientSendable: AnyObject {
    func send(text: String)
    func sendPing()
    func sendCloseAndDisconnect(code: UInt16, reason: String?)
}

extension WebSocketConnection: WSClientSendable {}

// MARK: - NativeWebSocketConnection

/// Wraps an NWConnection upgraded via NWProtocolWebSocket.Options.
/// Network.framework handles the RFC 6455 handshake and framing — no manual SHA-1 or codec.
final class NativeWebSocketConnection: @unchecked Sendable {
    let id: String
    let connection: NWConnection

    var onMessage: (@Sendable (String) -> Void)?
    var onClose: (@Sendable (UInt16, String?) -> Void)?
    var onPong: (@Sendable () -> Void)?

    private var isClosed = false
    private let lock = NSLock()

    init(id: String, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }

    // MARK: - Reading

    func startReading() {
        readNext()
    }

    private func readNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, context, isComplete, error in
            guard let self else { return }

            if let error {
                canvasLog("[NativeWS:\(self.id.prefix(8))] read error: \(error)")
                self.doClose(code: 1006)
                return
            }

            // data == nil with no context means TCP closed without a WS close frame.
            if data == nil && context == nil {
                self.doClose(code: 1006)
                return
            }

            // NOTE: For NWProtocolWebSocket, isComplete = true means the WebSocket MESSAGE
            // is complete (all fragments received). It does NOT mean the connection is closing.
            // Connection close is signalled by error (above), WS close opcode (below), or nil data.

            var continueReading = true

            if let context,
               let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text:
                    if let data, let text = String(data: data, encoding: .utf8) {
                        self.onMessage?(text)
                    }
                case .pong:
                    self.onPong?()
                case .close:
                    self.doClose(code: 1000)
                    continueReading = false
                default:
                    break // .cont, .binary, .ping (autoReplyPing handles pings automatically)
                }
            }

            if continueReading {
                self.readNext()
            }
        }
    }

    // MARK: - Sending

    func send(text: String) {
        lock.lock(); let closed = isClosed; lock.unlock()
        guard !closed, let data = text.data(using: .utf8) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    func sendPing() {
        lock.lock(); let closed = isClosed; lock.unlock()
        guard !closed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .ping)
        let ctx = NWConnection.ContentContext(identifier: "ping", metadata: [meta])
        connection.send(content: Data(), contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    func sendCloseAndDisconnect(code: UInt16 = 1000, reason: String? = nil) {
        lock.lock()
        if isClosed { lock.unlock(); return }
        isClosed = true
        lock.unlock()
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        // Close code written as two big-endian bytes in the payload per RFC 6455
        var payload = Data()
        payload.append(UInt8((code >> 8) & 0xFF))
        payload.append(UInt8(code & 0xFF))
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        connection.send(content: payload, contentContext: ctx, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
        onClose?(code, reason)
    }

    private func doClose(code: UInt16) {
        lock.lock()
        if isClosed { lock.unlock(); return }
        isClosed = true
        lock.unlock()
        onClose?(code, nil)
        connection.cancel()
    }
}

extension NativeWebSocketConnection: WSClientSendable {}
