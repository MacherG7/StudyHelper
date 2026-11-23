import PhotosUI
import StudyData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

/// "Lernstoff importieren": photo library, camera, document scanner and PDF.
struct ImportMenu: View {
    let subject: Subject
    @Environment(ImportCoordinator.self) private var coordinator

    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var showFileImporter = false
    @State private var pdfURLs: [URL] = []
    @State private var showPDFSheet = false
    @State private var errorMessage: String?

    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
    private let scannerAvailable = VNDocumentCameraViewController.isSupported

    var body: some View {
        Menu {
            Button("Fotomediathek", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            if cameraAvailable {
                Button("Kamera", systemImage: "camera") { showCamera = true }
            }
            if scannerAvailable {
                Button("Dokumentenscanner", systemImage: "doc.viewfinder") { showScanner = true }
            }
            Button("PDF oder Goodnotes-Export", systemImage: "doc.richtext") { showFileImporter = true }
        } label: {
            Label("Lernstoff importieren", systemImage: "square.and.arrow.down")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(coordinator.isRunning)
        .accessibilityIdentifier("importButton")
        .photosPicker(
            isPresented: $showPhotoPicker, selection: $photoSelection,
            maxSelectionCount: 30, selectionBehavior: .ordered, matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            coordinator.importPhotoItems(items, into: subject)
            photoSelection = []
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                coordinator.importImages([image], kind: .photo, into: subject)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(onImages: { images in
                coordinator.importImages(images, kind: .scan, into: subject)
            }, onError: { error in
                // Shown once the scanner is gone (an alert cannot appear over a full-screen cover).
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    errorMessage = "Der Dokumentenscanner hat nicht funktioniert: \(error.localizedDescription)"
                }
            })
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, UTType(filenameExtension: "goodnotes") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if let goodnotes = urls.first(where: { PDFLoader.isGoodnotesFile($0) }) {
                    errorMessage = PDFLoadError.goodnotesFile(goodnotes.lastPathComponent).errorDescription
                } else if urls.count > 2 {
                    errorMessage = "Bitte wähle höchstens zwei Dateien: das bearbeitbare und das reduzierte Goodnotes-PDF derselben Notiz."
                } else if !urls.isEmpty {
                    pdfURLs = urls
                    showPDFSheet = true
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showPDFSheet) {
            PDFImportSheet(subject: subject, urls: pdfURLs, incoming: nil)
        }
        .errorAlert($errorMessage)
    }
}

/// UIImagePickerController (camera) for one photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// VisionKit document scanner; returns all scanned pages.
struct DocumentScanner: UIViewControllerRepresentable {
    let onImages: ([UIImage]) -> Void
    let onError: (Error) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.onImages(images)
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onError(error)
            parent.dismiss()
        }
    }
}
