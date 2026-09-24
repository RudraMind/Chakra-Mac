import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut registered through Carbon.
///
/// `NSEvent.addGlobalMonitorForEvents` would make macOS demand Accessibility
/// permission. `RegisterEventHotKey` needs none, which is the entire reason for
/// reaching back to a 20-year-old API.
final class HotKey {
    /// 'CHKR' — identifies our own hot keys in the shared event stream.
    private static let signature: OSType = 0x43484B52

    /// The C callback cannot capture context, so it looks its handler up here.
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handler: EventHandlerRef?

    private let id: UInt32
    private let action: () -> Void
    private var ref: EventHotKeyRef?

    /// Why a shortcut could not be claimed.
    ///
    /// The two reasons need different words. A combination another app owns is
    /// fixed by picking a different one; a handler that would not install is not,
    /// and telling the user to pick another shortcut would send them round a loop
    /// that provably cannot end.
    enum Failure {
        case combinationTaken
        case cannotListen
    }

    /// Returns nil when the shortcut could not be claimed, with `failure` set to
    /// which of the two reasons it was.
    init?(keyCode: UInt32, modifiers: UInt32, failure: inout Failure?,
          action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1

        guard Self.installHandlerIfNeeded() else {
            failure = .cannotListen
            return nil
        }
        var created: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                        GetEventDispatcherTarget(), 0, &created)
        guard status == noErr, let created else {
            failure = .combinationTaken
            return nil
        }
        failure = nil
        ref = created
        // Retained by the table until invalidate(), so the caller does not have to
        // keep it alive for the callback to work.
        Self.instances[id] = self
    }

    /// Must be called explicitly: the static table holds a strong reference, so
    /// `deinit` would never run on its own.
    func invalidate() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.instances[id] = nil
    }

    private static func installHandlerIfNeeded() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // No captures: this closure has to convert to a C function pointer.
        let callback: EventHandlerUPP = { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == HotKey.signature,
                  let hotKey = HotKey.instances[pressed.id] else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.action()
            return noErr
        }
        var installed: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(), callback,
                                        1, &spec, nil, &installed)
        guard status == noErr else { return false }
        handler = installed
        return true
    }
}
