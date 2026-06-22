import Foundation
import CoreGraphics

final class SourceRevealHotkeyMonitor: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isActive = false
    private var onChange: (@Sendable (Bool) -> Void)?

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        guard eventTap == nil else { return }

        self.onChange = onChange

        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            print("[ScreenCommentator] Input Monitoring permission requested for source reveal hotkey")
            return
        }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .flagsChanged, let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<SourceRevealHotkeyMonitor>
                .fromOpaque(refcon)
                .takeUnretainedValue()
            monitor.update(flags: event.flags)
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            print("[ScreenCommentator] Failed to create source reveal event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        print("[ScreenCommentator] Source reveal hotkey monitoring started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        setActive(false)
        onChange = nil
    }

    private func update(flags: CGEventFlags) {
        let active = flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
            && flags.contains(.maskCommand)
        setActive(active)
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onChange?(active)
    }
}
