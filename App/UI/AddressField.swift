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
    let onSubmit: @MainActor (String) -> Void

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
        context.coordinator.parent = self
        focus.field = field
        if tabID != focus.shownTabID {
            focus.shownTabID = tabID
            if field.currentEditor() != nil { field.abortEditing() }
            field.stringValue = text
        } else if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField

        init(_ parent: AddressField) { self.parent = parent }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                control.stringValue = parent.text
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        /// Leaving the field shows the tab's URL again rather than half-typed text.
        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NSTextField)?.stringValue = parent.text
        }
    }
}
