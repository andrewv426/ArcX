import AppKit
import SwiftUI

/// Lets AppKit menu actions (⌘L, ⌘T) put the caret in the sidebar's address field. It holds the
/// field's `NSTextField`, so focusing is one `makeFirstResponder` call with no SwiftUI focus state
/// to round-trip through.
@MainActor
final class AddressFieldFocus {
    fileprivate(set) weak var field: NSTextField?
    /// The tab whose address the field last showed.
    fileprivate var shownTabID: UUID?

    /// Shows `text` for `tabID`, makes the field first responder and selects the text. Setting the
    /// text here rather than waiting for SwiftUI matters for ⌘T: the new tab's (empty) address must
    /// be in the field before editing starts, because edits are never overwritten by updates.
    func focus(text: String, tabID: UUID?) {
        guard let field, let window = field.window else { return }
        if field.currentEditor() == nil { field.stringValue = text }
        shownTabID = tabID
        window.makeFirstResponder(field)
        field.currentEditor()?.string = text
        field.currentEditor()?.selectAll(nil)
    }

    /// True while the field is being edited.
    var isEditing: Bool { field?.currentEditor() != nil }

    /// The text currently in the field, for tests.
    var text: String { field?.stringValue ?? "" }
}

/// The temporary address bar (until the M2 command bar): an `NSTextField`, so AppKit controls focus
/// and selection exactly. It shows `text` (the selected tab's URL). While the user edits it, page
/// updates do not overwrite the typing, but switching to another tab does. Return submits, Escape
/// puts the URL back.
struct AddressField: NSViewRepresentable {
    var text: String
    var tabID: UUID?
    let focus: AddressFieldFocus
    /// Returns the address text to keep showing while navigation starts, or nil if input was ignored.
    let onSubmit: @MainActor (String) -> String?
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "Search or enter address"
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focus.field = field
        focus.shownTabID = tabID
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        focus.field = field
        if tabID != focus.shownTabID {
            focus.shownTabID = tabID
            coordinator.clearPendingSubmission()
            if field.currentEditor() != nil { field.abortEditing() }
            field.stringValue = text
        } else if let pending = coordinator.pendingSubmittedText {
            if text != coordinator.parentTextAtSubmit || text == pending {
                coordinator.clearPendingSubmission()
                if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
            } else if field.currentEditor() == nil, field.stringValue != pending {
                field.stringValue = pending
            }
        } else if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        /// Held between Return and WebKit reporting the new URL, so ending editing or a SwiftUI
        /// pass does not flash the previous URL back into the bar while a page loads.
        fileprivate var pendingSubmittedText: String?
        fileprivate var parentTextAtSubmit: String?
        private var isSubmitting = false

        init(_ parent: AddressField) { self.parent = parent }

        fileprivate func clearPendingSubmission() {
            pendingSubmittedText = nil
            parentTextAtSubmit = nil
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            clearPendingSubmission()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                isSubmitting = true
                defer { isSubmitting = false }
                if let submitted = parent.onSubmit(control.stringValue) {
                    pendingSubmittedText = submitted
                    parentTextAtSubmit = parent.text
                    control.stringValue = submitted
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                clearPendingSubmission()
                control.stringValue = parent.text
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        /// Leaving the field shows the tab's URL again rather than half-typed text, except when
        /// Return just submitted a new navigation.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isSubmitting else { return }
            (notification.object as? NSTextField)?.stringValue = pendingSubmittedText ?? parent.text
        }
    }
}
