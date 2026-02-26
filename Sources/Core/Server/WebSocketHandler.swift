import Foundation
import Network

// MARK: - WSClientSendable

/// Unified send interface for WebSocket connections.
/// Lets WorldTreeServer treat all WebSocket clients identically.
protocol WSClientSendable: AnyObject {
    func send(text: String)
    func sendPing()
    func sendCloseAndDisconnect(code: UInt16, reason: String?)
}

// MARK: - NativeWebSocketConnection

/// Wraps an NWConnection upgraded via NWProtocolWebSocket.Options.
/// Network.framework handles the RFC 6455 handshake and framing automatically —
/// no manual SHA-1, frame parsing, or fragment reassembly needed.
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
                wtLog("[WebSocket:\(self.id.prefix(8))] read error: \(error)")
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
