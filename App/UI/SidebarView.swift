import AppKit
import ArcXCore
import SwiftUI

/// Where the window's traffic lights are, measured by the window controller, so the sidebar's
/// first row sits beside them rather than under them.
struct TitlebarMetrics {
    /// From the sidebar's leading edge to just past the zoom button.
    var trafficLightsTrailing: CGFloat
    /// A row this tall, starting at the top of the window, is vertically centred on the lights.
    var rowHeight: CGFloat
}

/// The vertical sidebar: navigation buttons beside the traffic lights, the address field, the
/// tab list and a New Tab row. It reads `BrowserState` for tabs and `TabSessionStore` for live
/// per-tab state (loading, back/forward), both through Observation; it never sees WebKit.
struct SidebarView: View {
    let state: BrowserState
    let sessions: TabSessionStore
    let tabs: TabCoordinator
    let addressFocus: AddressFieldFocus
    let titlebar: TitlebarMetrics
    let newTab: @MainActor () -> Void
    /// What Return in the address field does (returns the display URL while loading, or nil if ignored).
    let submitAddress: @MainActor (String) -> String?
    /// What Escape in the address field does (returns keyboard focus to the page).
    let cancelAddress: @MainActor () -> Void

    private var selectedSession: TabSession? {
        state.selectedTabID.flatMap(sessions.existingSession(for:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            navigationRow
            AddressField(text: tabs.addressText, tabID: state.selectedTabID, focus: addressFocus,
                         onSubmit: submitAddress, onCancel: cancelAddress)
                .frame(height: 28)
                .padding(.horizontal, 10)
            tabList
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var navigationRow: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            NavigationButton(symbol: "chevron.left", help: "Back", enabled: selectedSession?.canGoBack == true) { tabs.goBack() }
            NavigationButton(symbol: "chevron.right", help: "Forward", enabled: selectedSession?.canGoForward == true) { tabs.goForward() }
            NavigationButton(symbol: "arrow.clockwise", help: "Reload", enabled: selectedSession != nil) { tabs.reload() }
        }
        .padding(.leading, titlebar.trafficLightsTrailing)
        .padding(.trailing, 8)
        .frame(height: titlebar.rowHeight)
    }

    private var tabList: some View {
        List(selection: Binding(get: { state.selectedTabID }, set: { id in if let id { state.select(id) } })) {
            ForEach(state.tabs) { tab in
                TabRow(tab: tab, isLoading: sessions.existingSession(for: tab.id)?.isLoading == true) {
                    state.closeTab(tab.id)
                }
                .tag(tab.id)
                .contextMenu {
                    Button("Close Tab") { state.closeTab(tab.id) }
                    Button("Copy Link") { copy(tab.url) }
                        .disabled(tab.url == nil)
                }
            }
            .onMove { state.moveTabs(fromOffsets: $0, toOffset: $1) }

            Button(action: newTab) {
                Label("New Tab", systemImage: "plus")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// One tab: a placeholder icon, the title on one line, a spinner while loading and a close
/// button on hover. The list draws the selected state.
private struct TabRow: View {
    let tab: ArcXCore.Tab
    let isLoading: Bool
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            if isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
            }
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }
}

private struct NavigationButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}
