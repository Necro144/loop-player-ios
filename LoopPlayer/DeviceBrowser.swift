import SwiftUI

/// Opens the built-in folder browser (only shown when the app runs without a sandbox,
/// i.e. installed with TrollStore from the .tipa).
struct BrowsePhoneButton: View {
    var prominent = false
    @EnvironmentObject var ui: AppUI

    var body: some View {
        Button {
            ui.showPhoneBrowser = true
        } label: {
            if prominent {
                Label("Browse iPhone Folders", systemImage: "iphone")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundColor(.white)
            } else {
                Label("Browse iPhone Folders", systemImage: "iphone")
            }
        }
        .accessibilityIdentifier("browsePhone")
    }
}

/// iCloud Drive and On My iPhone, read directly from the phone. No system picker involved.
struct PhoneBrowserView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DeviceFolders.places) { place in
                        NavigationLink {
                            PhoneFolderView(url: place.url, title: place.name, onUse: use)
                        } label: {
                            Label(place.name, systemImage: place.icon)
                                .padding(.vertical, 6)
                        }
                        .listRowBackground(Theme.surface)
                    }
                } footer: {
                    Text("Open the folder with your songs, then tap Use This Folder. Subfolders are included.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Choose a Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func use(_ url: URL) {
        library.addDeviceFolder(url)
        dismiss()
    }
}

struct PhoneFolderView: View {
    let url: URL
    let title: String
    let onUse: (URL) -> Void
    @State private var listing: DeviceFolders.Listing?

    var body: some View {
        List {
            Section {
                Button {
                    onUse(url)
                } label: {
                    Label("Use This Folder", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(Theme.accent)
                }
                .accessibilityIdentifier("useThisFolder")
                .listRowBackground(Theme.surface)
            } footer: {
                if let listing {
                    Text(listing.media == 1 ? "1 song or video here" : "\(listing.media) songs or videos here")
                        + Text(listing.folders.isEmpty ? "." : ", plus what is in the folders below.")
                }
            }
            if let listing {
                if !listing.folders.isEmpty {
                    Section("Folders") {
                        ForEach(listing.folders, id: \.self) { sub in
                            NavigationLink {
                                PhoneFolderView(url: sub, title: sub.lastPathComponent, onUse: onUse)
                            } label: {
                                Label(sub.lastPathComponent, systemImage: "folder.fill")
                            }
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Theme.bg)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let u = url
            listing = await Task.detached(priority: .userInitiated) { DeviceFolders.list(u) }.value
        }
    }
}
