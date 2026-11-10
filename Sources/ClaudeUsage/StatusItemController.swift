import AppKit
import ClaudeUsageCore
import Observation
import SwiftUI

/// Owns the menu bar item and the popover it toggles.
///
/// The title is drawn as an attributed string rather than a SwiftUI label so the
/// two percentages can be colored independently and share a monospaced-digit
/// font, which stops the item resizing as the numbers change width.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(store: UsageStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        let hosting = NSHostingController(rootView: UsagePanel(store: store))
        // Without this the controller never reports its size, so the popover
        // keeps AppKit's default 320x320 contentSize: it anchors for a 320-tall
        // panel, then the window shrinks to fit from the top and leaves a gap
        // the height of the difference.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.delegate = self

        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        // Right-click opens the account menu instead of the panel.
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        renderTitle()
        observeStore()
    }

    // MARK: - Title

    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        guard let snapshot = store.combined else {
            button.attributedTitle = NSAttributedString(
                string: store.headlineError == nil ? "…" : "—",
                attributes: [
                    .font: Self.titleFont,
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.5),
                ]
            )
            button.toolTip = store.headlineError ?? "Loading Claude usage…"
            return
        }

        // Dim the whole title when the numbers on screen are no longer fresh.
        let dimmed = store.isStale
        let title = NSMutableAttributedString()

        func append(_ window: LimitWindow?) {
            guard let window else { return }
            if title.length > 0 {
                title.append(NSAttributedString(
                    string: " · ",
                    attributes: [.font: Self.titleFont, .foregroundColor: NSColor.tertiaryLabelColor]
                ))
            }
            var color: NSColor
            switch Severity.forPercent(window.percent) {
            case .normal: color = .labelColor
            case .warning: color = .systemYellow
            case .critical: color = .systemRed
            }
            if dimmed { color = color.withAlphaComponent(0.45) }
            title.append(NSAttributedString(
                string: Format.percent(window.percent),
                attributes: [.font: Self.titleFont, .foregroundColor: color]
            ))
        }

        append(snapshot.fiveHour)
        append(snapshot.weekly)
        button.attributedTitle = title

        var tooltip = store.accounts.count > 1 ? "Claude usage · \(store.accounts.count) accounts combined" : "Claude usage"
        if let fiveHour = snapshot.fiveHour {
            tooltip += "\n5-hour: " + Format.detail(percent: fiveHour.percent, resetsAt: fiveHour.resetsAt, now: store.now)
        }
        if let weekly = snapshot.weekly {
            tooltip += "\nWeekly: " + Format.detail(percent: weekly.percent, resetsAt: weekly.resetsAt, now: store.now)
        }
        if let error = store.headlineError {
            tooltip += "\n\n\(error)"
        }
        button.toolTip = tooltip
    }

    /// Re-registers after each change; observation tracking is single-shot.
    private func observeStore() {
        withObservationTracking {
            _ = store.accounts
            _ = store.lastError
            _ = store.now
        } onChange: {
            Task { @MainActor [weak self] in
                self?.renderTitle()
                self?.observeStore()
            }
        }
    }

    // MARK: - Clicks

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if wantsMenu {
            showMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - Menu

    /// Built per click so the account list is always current.
    private func showMenu() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        let add = NSMenuItem(
            title: store.isSigningIn ? "Waiting for Browser…" : (store.accounts.isEmpty ? "Sign In…" : "Add Account…"),
            action: store.isSigningIn ? nil : #selector(addAccount),
            keyEquivalent: ""
        )
        add.target = self
        menu.addItem(add)

        if !store.accounts.isEmpty {
            menu.addItem(.separator())
            for state in store.accounts {
                let remove = NSMenuItem(title: "Remove \(state.title)", action: #selector(removeAccount(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = state.id
                menu.addItem(remove)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Pop up under the item, as the system's own status menus do.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func addAccount() {
        store.signIn()
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let state = store.accounts.first(where: { $0.id == key })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(state.title)?"
        alert.informativeText = "Its usage stops showing. Sign in again to add it back."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.remove(state)
    }

    // MARK: - Popover

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            store.refresh()
            // An accessory app is not active, so its popover would open behind
            // the frontmost app and immediately dismiss itself. Activate first,
            // then take key focus so `.transient` tracks clicks correctly.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }
}
