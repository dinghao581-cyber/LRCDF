import CoreImage
import Foundation
import Photos
import SwiftUI

/// One imported photo: its copy in the app's folder, a preview-size decode and what the model said about it.
final class Photo: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    var preview: CIImage?
    var grades: [Int: Grade] = [:]
    var thumb: CGImage?
    var faces: [Face] = []
    var edits: [CIImage?] = []      // blemish model on the preview
    var memos: [String: BeautyMemo] = [:]   // retouching measurements, per look
    var fullWidth: CGFloat = 0
    init(url: URL) { self.url = url }
}

@MainActor
final class Studio: ObservableObject {
    enum Stage: Equatable { case empty, working(String), ready, exporting(Int, Int), done(Int) }

    @Published var photos: [Photo] = []
    @Published var current: UUID?
    @Published var look: String = "a"
    @Published var tweak = Tweak()
    @Published var beauty: BeautyLevel = .natural
    @Published var faceCards: [BeautyLevel: CGImage] = [:]   // the main face at each level
    @Published var stage: Stage = .empty
    @Published var showOriginal = false
    @Published var picture: CGImage?            // what is on screen
    @Published var cards: [String: CGImage] = [:] // one small picture per look, of the current photo
    @Published var message: String?

    private let engine = Engine.shared
    private let previewSide: CGFloat = 2400
    private var renderTask: Task<Void, Never>?

    var currentPhoto: Photo? { photos.first { $0.id == current } }

    nonisolated static let folder: URL = {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()

    // MARK: import

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fresh = urls.map { Photo(url: $0) }
        photos.append(contentsOf: fresh)
        if current == nil { current = fresh.first?.id }
        stage = .working("正在读取照片…")
        Task {
            for p in fresh { await prepare(p) }
            stage = .ready
            refresh()
        }
    }

    /// Decode at preview size, ask the model once (all styles), make a thumbnail. Off the main thread.
    private func prepare(_ p: Photo) async {
        let engine = self.engine, side = previewSide
        let ok: Bool = await Task.detached(priority: .userInitiated) {
            guard let img = try? engine.decode(p.url, maxSide: side) else { return false }
            p.preview = img
            p.grades = (try? engine.grades(for: img)) ?? [:]
            p.faces = Beauty.shared.faces(in: img)
            p.fullWidth = engine.fullWidth(p.url) ?? img.extent.width
            p.edits = Beauty.shared.edits(img, faces: p.faces, fullWidth: p.fullWidth)
            let s = 220 / max(img.extent.width, img.extent.height)
            p.thumb = engine.cgImage(img.transformed(by: CGAffineTransform(scaleX: s, y: s)))
            return true
        }.value
        if !ok {
            message = "有一张照片打不开：\(p.url.lastPathComponent)"
            photos.removeAll { $0.id == p.id }
            if current == p.id { current = photos.first?.id }
        }
        if p.id == current { refresh() }
        objectWillChange.send()
    }

    func select(_ id: UUID) { current = id; refresh() }

    // MARK: rendering

    /// Re-renders what is on screen and the look cards. Cheap: the model ran at import.
    func refresh() {
        guard let p = currentPhoto, let img = p.preview else { picture = nil; return }
        let engine = self.engine, look = Look.all.first { $0.id == self.look }, tweak = self.tweak
        let original = showOriginal, level = beauty
        let memo = p.memos[self.look] ?? BeautyMemo()
        p.memos[self.look] = memo
        renderTask?.cancel()
        renderTask = Task {
            let (main, cards, faceCards) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, [String: CGImage], [BeautyLevel: CGImage]) in
                let grade = look?.style.flatMap { p.grades[$0] }
                let shown = original ? img : engine.render(img, grade: grade, tweak: tweak, beauty: BeautyJob(faces: p.faces, edits: p.edits, level: level, memo: memo, fullWidth: p.fullWidth))
                let main = engine.cgImage(shown)
                // the largest face at each level, for the beauty cards
                var faceCards: [BeautyLevel: CGImage] = [:]
                if let f = p.faces.max(by: { $0.width < $1.width }) {
                    let W = img.extent.width, H = img.extent.height
                    let c = CGPoint(x: f.box.midX * W, y: f.box.midY * H), side = max(f.box.width * W, f.box.height * H) * 1.25
                    let r = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side).intersection(img.extent)
                    for l in BeautyLevel.allCases {
                        let full = engine.render(img, grade: grade, tweak: tweak, beauty: BeautyJob(faces: p.faces, edits: p.edits, level: l, memo: memo, fullWidth: p.fullWidth))
                        let s = min(1, 300 / r.width)
                        if let cg = engine.cgImage(full.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY).concatenating(CGAffineTransform(scaleX: s, y: s)))) { faceCards[l] = cg }
                    }
                }
                var cards: [String: CGImage] = [:]
                let s = 360 / max(img.extent.width, img.extent.height)
                let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
                for l in Look.all {
                    let g = l.style.flatMap { p.grades[$0] }
                    if let c = engine.cgImage(engine.render(small, grade: g, tweak: Tweak())) { cards[l.id] = c }
                }
                return (main, cards, faceCards)
            }.value
            if Task.isCancelled { return }
            picture = main; self.cards = cards; self.faceCards = faceCards
        }
    }

    // MARK: export

    /// Every imported photo, full size, with the chosen look and tweaks, into the photo library.
    func exportAll() {
        let list = photos, engine = self.engine, tweak = self.tweak, level = beauty
        let style = Look.all.first { $0.id == look }?.style, lookID = look
        stage = .exporting(0, list.count)
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                message = "没有存进相册的权限：请在 设置 → 隐私 → 照片 里允许。"; stage = .ready; return
            }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var done = 0
            for (i, p) in list.enumerated() {
                stage = .exporting(i, list.count)
                let file: URL? = await Task.detached(priority: .userInitiated) {
                    try? engine.export(p.url, grade: style.flatMap { p.grades[$0] }, tweak: tweak, faces: p.faces, level: level, memo: p.memos[lookID], to: out)
                }.value
                guard let file else { continue }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let req = PHAssetCreationRequest.forAsset()
                        let opt = PHAssetResourceCreationOptions(); opt.shouldMoveFile = true
                        req.addResource(with: .photo, fileURL: file, options: opt)
                    }
                    done += 1
                } catch { message = "存进相册失败：\(error.localizedDescription)" }
            }
            stage = .done(done)
        }
    }
}
