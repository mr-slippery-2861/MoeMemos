import SwiftUI
import Models

struct MemoEditorResourceView: View {
    var viewModel: MemoEditorViewModel
    @State private var showingOrder = false

    var body: some View {
        let mediaResources = viewModel.resourceList.filter {
            $0.mimeType.hasPrefix("image/") == true || $0.mimeType.hasPrefix("video/") == true
        }
        let attachmentResources = viewModel.resourceList.filter {
            $0.mimeType.hasPrefix("image/") == false && $0.mimeType.hasPrefix("video/") == false
        }

        if !viewModel.resourceList.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.resourceList.count > 1 {
                    Button("Reorder attachments", systemImage: "arrow.up.arrow.down") {
                        showingOrder = true
                    }
                    .font(.footnote)
                    .padding(.horizontal)
                }
                if !mediaResources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack {
                            ForEach(mediaResources, id: \.id) { item in
                                ResourceCard(resource: item, resourceManager: viewModel)
                            }
                        }
                        .frame(height: 80)
                        .padding([.leading, .trailing, .bottom])
                    }
                }

                if !attachmentResources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(attachmentResources, id: \.id) { item in
                                Attachment(resource: item, resourceManager: viewModel)
                                    .frame(maxWidth: 200, alignment: .leading)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.leading, .trailing, .bottom])
                }
            }
            .sheet(isPresented: $showingOrder) {
                NavigationStack {
                    List {
                        ForEach(viewModel.resourceList) { resource in
                            Text(resource.filename)
                        }
                        .onMove { source, destination in
                            viewModel.resourceList.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                    .navigationTitle("Reorder attachments")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingOrder = false }
                        }
                    }
                }
            }
        }
    }
}
