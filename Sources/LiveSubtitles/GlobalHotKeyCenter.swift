//
//  GlobalHotKeyCenter.swift
//  LiveSubtitles
//
//  System-wide hot keys via Carbon's RegisterEventHotKey.
//
//  Deliberately not `NSEvent.addGlobalMonitorForEvents`: monitoring the keyboard that
//  way requires Accessibility permission, and this app has no business asking for it
//  just so you can pause the captions.
//

import AppKit
import Carbon.HIToolbox

final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installedEventHandler = false

    private init() {}

    func unregisterAll() {
        for reference in references.values {
            UnregisterEventHotKey(reference)
        }
        references.removeAll()
        handlers.removeAll()
    }

    /// Swap in a fresh set of shortcuts. Any that the system refuses (usually because
    /// another app already owns the combination) are simply skipped.
    @discardableResult
    func replaceAll(with shortcuts: [(KeyShortcut, () -> Void)]) -> [KeyShortcut] {
        unregisterAll()
        installEventHandlerIfNeeded()

        var rejected: [KeyShortcut] = []
        for (shortcut, handler) in shortcuts {
            guard shortcut.carbonModifiers != 0 else { continue }
            let id = nextID
            nextID += 1

            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4C535542), id: id)  // 'LSUB'
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode),
                                             shortcut.carbonModifiers,
                                             hotKeyID,
                                             GetApplicationEventTarget(),
                                             0,
                                             &reference)
            if status == noErr, let reference {
                references[id] = reference
                handlers[id] = handler
            } else {
                rejected.append(shortcut)
            }
        }
        return rejected
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard !installedEventHandler else { return }
        installedEventHandler = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            if status == noErr {
                GlobalHotKeyCenter.shared.fire(hotKeyID.id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
