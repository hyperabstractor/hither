import Shared
import SwiftUI

/// Each paired Mac's open windows (tap one to show it) and apps, and Macs nearby to pair with.
struct HomeView: View {
    @ObservedObject var macs: Macs
    @State private var showing: Showing?

    struct Showing: Identifiable {
        let id = UUID()
        let mac: Peer, item: Item
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(macs.paired, id: \.id) { mac in
                    let windows = macs.windows[mac.id] ?? []
                    Section(mac.name) {
                        if macs.stopsSharing(mac) {
                            Text("\(mac.name) isn't sharing its windows. Turn on Share This Mac in Hither's menu there.")
                                .foregroundStyle(.secondary)
                        } else if windows.isEmpty {
                            Text(macs.state[mac.id, default: ""].isEmpty ? "No windows open" : macs.state[mac.id]!)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(windows, id: \.id) { w in
                            Button { show(w, on: mac) } label: { AppRow(item: w, icon: macs.icons[w.bundle], detail: w.title) }
                                .swipeActions { Button("Close", role: .destructive) { macs.close(w, on: mac) } }
                        }
                        NavigationLink("All Apps") { AppsView(macs: macs, mac: mac) { show($0, on: mac) } }
                    }
                }
                let unpaired = macs.nearby.filter { n in !macs.paired.contains { $0.id == n.id } }
                if macs.paired.isEmpty || !unpaired.isEmpty || macs.noLocalNetwork {
                    Section {
                        if unpaired.isEmpty {
                            HStack(spacing: 10) { ProgressView(); Text("Looking for Macs running Hither…").foregroundStyle(.secondary) }
                        }
                        ForEach(unpaired) { n in
                            Button { macs.pair(with: n) } label: {
                                Label {
                                    Text("Pair with \(n.name)")
                                    if !n.shares { Text("Share This Mac is off").font(.caption).foregroundStyle(.secondary) }
                                } icon: {
                                    Image(systemName: "desktopcomputer")
                                }
                            }
                            .disabled(!n.shares)
                        }
                    } header: {
                        Text("Nearby Macs")
                    } footer: {
                        Text(macs.noLocalNetwork
                             ? "Hither can't look for Macs: turn on Local Network for it in Settings › Apps › Hither."
                             : "Open Hither on the Mac. You'll check that both screens show the same code.")
                    }
                }
            }
            .navigationTitle("Hither")
            .refreshable { await MainActor.run { macs.refresh() } }
            .toolbar {
                if !macs.paired.isEmpty {
                    Menu {
                        ForEach(macs.paired, id: \.id) { mac in
                            Button("Unpair \(mac.name)", systemImage: "xmark.circle", role: .destructive) { macs.unpair(mac) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $macs.prompt) { CodeSheet(prompt: $0) }
        .alert("Couldn't Pair", isPresented: Binding(get: { macs.problem != nil }, set: { if !$0 { macs.problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(macs.problem ?? "")
        }
        .fullScreenCover(item: $showing, onDismiss: { macs.refresh() }) { StreamScreen(mac: $0.mac, item: $0.item) }
    }

    func show(_ item: Item, on mac: Peer) {
        showing = Showing(mac: mac, item: item)
    }
}

struct AppRow: View {
    let item: Item, icon: UIImage?, detail: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon { Image(uiImage: icon).resizable() } else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.app).foregroundStyle(.primary)
                if !detail.isEmpty && detail != item.app {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Every app installed on the Mac. Opening one that isn't running launches it there.
struct AppsView: View {
    @ObservedObject var macs: Macs
    let mac: Peer
    let open: (Item) -> Void
    @State private var search = ""

    var body: some View {
        let apps = macs.apps[mac.id] ?? []
        let shown = search.isEmpty ? apps : apps.filter { $0.app.localizedCaseInsensitiveContains(search) }
        List(shown, id: \.bundle) { a in
            Button { open(a) } label: { AppRow(item: a, icon: macs.icons[a.bundle], detail: "") }
        }
        .overlay { if apps.isEmpty { ProgressView() } }
        .searchable(text: $search)
        .navigationTitle("Apps on \(mac.name)")
        .onAppear { if apps.isEmpty { macs.loadApps(mac) } }
    }
}

/// The 6-digit code, to compare with the Mac's.
struct CodeSheet: View {
    let prompt: CodePrompt
    @State private var sent = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair with \(prompt.mac)?").font(.title2.bold())
            Text(prompt.code).font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
            Text(sent ? "Now click Pair on \(prompt.mac)." : "Check that \(prompt.mac) shows the same code. Once paired, this iPhone can open and control the Mac's apps.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if sent {
                ProgressView()
            } else {
                Button { sent = true; prompt.answer(true) } label: { Text("Pair").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Button("Cancel", role: .cancel) { prompt.answer(false) }
        }
        .padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
