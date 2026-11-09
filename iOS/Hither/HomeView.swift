import Shared
import SwiftUI
import UniformTypeIdentifiers

/// Each paired Mac: its Desktop, its open windows (tap one to show it), its apps and its settings; and Macs nearby
/// to pair with.
struct HomeView: View {
    @ObservedObject var macs: Macs
    @State private var showing: Showing?
    @State private var askingAddress = false
    @State private var address = ""
    @State private var locking: MacRef?
    @State private var sendingFiles: MacRef?

    struct Showing: Identifiable {
        let id = UUID()
        let mac: Peer, item: Item
    }

    /// A paired Mac, for sheets and dialogs about it.
    struct MacRef: Identifiable {
        let mac: Peer
        var id: String { mac.id }
    }

    static let desktop = Item(id: 0, app: "Desktop", bundle: desktopApp, title: "")

    var body: some View {
        NavigationStack {
            List {
                ForEach(macs.paired, id: \.id) { mac in section(mac) }
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
                        if macs.paired.isEmpty {
                            Button("Pair with Mac at Address…", systemImage: "network") { askingAddress = true }
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
                Menu {
                    Button("Pair with Mac at Address…", systemImage: "network") { askingAddress = true }
                    if !macs.paired.isEmpty {
                        Divider()
                        ForEach(macs.paired, id: \.id) { mac in
                            Button("Unpair \(mac.name)", systemImage: "xmark.circle", role: .destructive) { macs.unpair(mac) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Pairing")
            }
            .safeAreaInset(edge: .bottom) { TransferBar(macs: macs) }
        }
        .sheet(item: $macs.prompt) { CodeSheet(prompt: $0) }
        .alert("Couldn't Pair", isPresented: Binding(get: { macs.problem != nil }, set: { if !$0 { macs.problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(macs.problem ?? "")
        }
        .alert("Pair with a Mac at an Address", isPresented: $askingAddress) {
            TextField("mini-pb or 100.x.y.z", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Pair") { macs.pair(address: address); address = "" }
            Button("Cancel", role: .cancel) { address = "" }
        } message: {
            Text("Its Tailscale name or IP address, for a Mac that isn't nearby. Hither must be running there, and you'll click Pair on its screen too. Hither keeps that address as a way back to it.")
        }
        .confirmationDialog(locking.map { "Lock \($0.mac.name)?" } ?? "", isPresented: Binding(get: { locking != nil }, set: { if !$0 { locking = nil } }),
                            titleVisibility: .visible, presenting: locking) { ref in
            Button("Lock", role: .destructive) { macs.lock(ref.mac) }
        } message: { _ in
            Text("It locks right away. Its Desktop shows the lock screen, where you can type its password.")
        }
        .sheet(item: $sendingFiles) { ref in
            DocumentPicker { urls in macs.sendFiles(urls, to: ref.mac, cleanup: urls) }.ignoresSafeArea()
        }
        .fullScreenCover(item: $showing, onDismiss: { macs.refresh() }) { StreamScreen(macs: macs, mac: $0.mac, item: $0.item) }
        #if DEBUG
        .onAppear(perform: testOpen)
        #endif
    }

    #if DEBUG
    /// Test hook: HITHER_TEST_OPEN=mini/@desktop (or mini/com.apple.TextEdit) opens that stream at launch, so it can be
    /// checked without tapping. A name that isn't paired opens one that can't connect: the controls, laid out.
    func testOpen() {
        guard let spec = ProcessInfo.processInfo.environment["HITHER_TEST_OPEN"], showing == nil else { return }
        let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let mac = macs.paired.first { $0.name == parts[0] } ?? Peer(id: "test-\(parts[0])", name: parts[0], token: Data(count: 32))
        show(parts[1] == desktopApp ? Self.desktop : Item(id: 0, app: parts[1], bundle: parts[1], title: ""), on: mac)
    }
    #endif

    @ViewBuilder func section(_ mac: Peer) -> some View {
        let windows = macs.windows[mac.id] ?? []
        let dark = macs.dark[mac.id] ?? false
        Section {
            Button { show(Self.desktop, on: mac) } label: {
                AppRow(item: Self.desktop, icon: nil, symbol: "display", detail: "Its whole screen: menu bar, Dock and every window")
            }
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
        } header: {
            HStack {
                Text(mac.name)
                if dark { Image(systemName: "moon.fill").accessibilityLabel("Keep Screen Dark is on") }
                Spacer()
                macMenu(mac, dark: dark)
            }
            .textCase(nil)
        } footer: {
            if dark {
                Text("Keep Screen Dark is on: \(mac.name)'s own monitors show black while you use it from here, and it locks 2 minutes after you close the last window.")
            }
        }
    }

    /// Everything else about a Mac, out of the way of its windows (as in its submenu on a Mac).
    func macMenu(_ mac: Peer, dark: Bool) -> some View {
        Menu {
            Section {
                Button("Send Clipboard to \(mac.name)", systemImage: "doc.on.clipboard") { macs.sendClipboard(to: mac) }
                Button("Get Clipboard from \(mac.name)", systemImage: "clipboard") { macs.getClipboard(from: mac) }
                Button("Send Files to \(mac.name)…", systemImage: "folder") { sendingFiles = MacRef(mac: mac) }
            }
            Section {
                Toggle(isOn: Binding(get: { dark }, set: { macs.setDark($0, on: mac) })) {
                    Label("Keep Screen Dark", systemImage: "moon")
                    Text("Its monitors show black while you use it; it locks 2 minutes after you stop")
                }
                Button("Lock \(mac.name)…", systemImage: "lock") { locking = MacRef(mac: mac) }
            }
            Section {
                let current = macs.codec[mac.id] ?? "h264"
                Picker(selection: Binding(get: { current }, set: { macs.setCodec($0, on: mac) })) {
                    Text("H.264").tag("h264")
                    Text("HEVC").tag("hevc")
                    if current == "hevc422" { Text("HEVC 4:2:2 (Macs only; HEVC here)").tag("hevc422") }
                } label: {
                    Label("Video Codec", systemImage: "film")
                    Text("For every window \(mac.name) sends")
                }
                .pickerStyle(.menu)
            }
            Section {
                Button("Unpair \(mac.name)", systemImage: "xmark.circle", role: .destructive) { macs.unpair(mac) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.body)
        }
        .accessibilityLabel("\(mac.name) settings")
    }

    func show(_ item: Item, on mac: Peer) {
        macs.remember(item, on: mac)
        showing = Showing(mac: mac, item: item)
    }
}

struct AppRow: View {
    let item: Item, icon: UIImage?
    var symbol: String? = nil
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon { Image(uiImage: icon).resizable() }
                else if let symbol { Image(systemName: symbol).resizable().scaledToFit().padding(3).foregroundStyle(.tint) }
                else { Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary) }
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

/// Every app installed on the Mac, the ones opened from here lately first. Opening one that isn't running launches
/// it there.
struct AppsView: View {
    @ObservedObject var macs: Macs
    let mac: Peer
    let open: (Item) -> Void
    @State private var search = ""

    var body: some View {
        let apps = macs.apps[mac.id] ?? []
        let shown = search.isEmpty ? apps : apps.filter { $0.app.localizedCaseInsensitiveContains(search) }
        let recent = search.isEmpty ? macs.recent(on: mac) : []
        List {
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.bundle) { a in
                        Button { open(a) } label: { AppRow(item: a, icon: macs.icons[a.bundle], detail: "") }
                    }
                }
            }
            Section(recent.isEmpty ? "" : "All Apps") {
                ForEach(shown, id: \.bundle) { a in
                    Button { open(a) } label: { AppRow(item: a, icon: macs.icons[a.bundle], detail: "") }
                }
            }
        }
        .overlay { if apps.isEmpty { ProgressView() } }
        .searchable(text: $search)
        .navigationTitle("Apps on \(mac.name)")
        .onAppear { if apps.isEmpty { macs.loadApps(mac) } }
    }
}

/// Files to send, picked in the Files app. iOS hands over copies, which the copy removes when it's done.
struct DocumentPicker: UIViewControllerRepresentable {
    let picked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(picked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let picked: ([URL]) -> Void
        init(_ picked: @escaping ([URL]) -> Void) { self.picked = picked }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { picked(urls) }
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
            Text(sent ? "Now click Pair on \(prompt.mac)." : "Check that \(prompt.mac) shows the same code. Once paired, this device can open and control the Mac's apps.")
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
