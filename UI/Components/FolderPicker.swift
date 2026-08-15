import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iOS 上选择文件夹的系统选择器。
///
/// SwiftUI 的 `fileImporter` 在 iOS 上不支持目录选择（点了没有反应），
/// 必须用 `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`。
/// 选中返回的 URL 是 security-scoped，调用方在使用/存书签前需
/// `startAccessingSecurityScopedResource()`（BackupManager 已处理）。
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void = { }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPicker

        init(parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
