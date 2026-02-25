import Cocoa
import Carbon.HIToolbox

/// Registers a global hotkey (default ⌘⇧Space) that brings World Tree to the front
/// from any other application — no Accessibility permission required.
///
/// Usage: call `GlobalHotKey.shared.register()` on app launch.
/// The user can disable via Settings → General → Global Hotkey.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: OSType(0x5754_524B), id: 1) // "WTRK"

    private init() {}

    func register() {
        guard UserDefaults.standard.bool(forKey: "globalHotKeyEnabled") else { return }
        guard hotKeyRef == nil else { return }

        // Read user-configured key combo; fall back to ⌘⇧Space
        let keyCode = UInt32(UserDefaults.standard.integer(forKey: "globalHotKeyCode").nonZero ?? kVK_Space)
        let modifiers = UInt32(UserDefaults.standard.integer(forKey: "globalHotKeyModifiers").nonZero
            ?? (cmdKey | shiftKey))

        // Install Carbon event handler
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                GlobalHotKey.shared.handleHotKey()
                return noErr
            },
            1, &eventSpec, nil, &eventHandlerRef
        )

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            wtLog("[GlobalHotKey] registered ⌘⇧Space (keyCode=\(keyCode), modifiers=\(modifiers))")
        } else {
            wtLog("[GlobalHotKey] registration failed: \(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    private func handleHotKey() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            // If all windows are hidden/miniaturized, bring the main window forward
            if let window = NSApp.windows.first(where: { $0.isVisible || $0.isMiniaturized }) {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            } else {
                // No visible window — post a new-tree notification to open one
                NotificationCenter.default.post(name: .createNewTree, object: nil)
            }
        }
    }
}

private extension Int {
    /// Returns nil if the value is zero (unset UserDefaults default).
    var nonZero: Int? { self == 0 ? nil : self }
}
