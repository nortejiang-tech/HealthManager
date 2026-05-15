import Foundation
import UIKit

/// Storage helper for meal photos.
///
/// Photos live under `Application Support/MealPhotos/` to stay out of iCloud Documents
/// and survive across app updates. We only store the relative filename in
/// `meal_records.photo_path` so the absolute path can be reconstructed and remains
/// valid even if the sandbox container UUID changes between launches.
final class MealPhotoStore {

    static let shared = MealPhotoStore()

    private let folder: URL
    private let thumbnailCache = NSCache<NSString, UIImage>()

    private init() {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("MealPhotos", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        self.folder = url
        thumbnailCache.countLimit = 64
    }

    /// Saves a JPEG (quality 0.85) and returns the *relative* filename, e.g.
    /// `8C2D9A7E-3FAB-4F1B-89E7-1234567890AB.jpg`. Returns nil on failure.
    func save(image: UIImage) -> String? {
        let filename = UUID().uuidString + ".jpg"
        let url = folder.appendingPathComponent(filename)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url, options: [.atomic])
            return filename
        } catch {
            AppLogger.shared.error("MealPhotoStore save failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Loads the full-resolution image for an editor preview.
    func loadImage(path: String) -> UIImage? {
        let url = absoluteURL(for: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Loads a 56×56-ish thumbnail for list rows. Cached in-memory.
    func loadThumbnail(path: String) -> UIImage? {
        if let cached = thumbnailCache.object(forKey: path as NSString) { return cached }
        let url = absoluteURL(for: path)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        let thumb = downscale(img, targetSide: 112)
        thumbnailCache.setObject(thumb, forKey: path as NSString)
        return thumb
    }

    /// Removes the underlying file if `path` refers to a file in our managed folder.
    /// No-op if the file lives elsewhere or doesn't exist.
    func removeIfManaged(path: String) {
        guard !path.contains("/") else { return }   // legacy absolute paths: don't touch
        let url = folder.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: url)
        thumbnailCache.removeObject(forKey: path as NSString)
    }

    /// Absolute URL on disk for a stored relative path.
    func absoluteURL(for path: String) -> URL {
        folder.appendingPathComponent(path)
    }

    // MARK: - Helpers

    private func downscale(_ image: UIImage, targetSide: CGFloat) -> UIImage {
        let scale = max(1, max(image.size.width, image.size.height) / targetSide)
        let newSize = CGSize(width: image.size.width / scale, height: image.size.height / scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
