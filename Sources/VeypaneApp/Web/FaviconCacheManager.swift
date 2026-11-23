import AppKit
import CryptoKit
import Foundation
import Observation
import VeypaneCore

/// Memory + disk cache for high-DPI pad favicons with automatic per-pad cancellation of stale loads (Outcome 2).
@MainActor
@Observable
public final class FaviconCacheManager {
    public var revision: Int = 0

    @ObservationIgnored
    private let diskDirectoryURL: URL

    @ObservationIgnored
    private let memoryCache = NSCache<NSString, NSImage>()

    @ObservationIgnored
    private var resolvedPadImages: [UUID: NSImage] = [:]

    @ObservationIgnored
    private var resolvedPadURLs: [UUID: URL] = [:]

    @ObservationIgnored
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private let urlSession: URLSession

    public init(diskDirectoryURL: URL) {
        self.diskDirectoryURL = diskDirectoryURL
        self.memoryCache.countLimit = 128

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6.0
        config.timeoutIntervalForResource = 10.0
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.urlSession = URLSession(configuration: config)
    }

    public func image(for pad: Pad) -> NSImage? {
        _ = revision
        if let direct = resolvedPadImages[pad.id] {
            return direct
        }
        if let faviconURL = pad.faviconURL {
            if let mem = memoryCache.object(forKey: faviconURL.absoluteString as NSString) {
                resolvedPadImages[pad.id] = mem
                resolvedPadURLs[pad.id] = faviconURL
                return mem
            }
            if let disk = loadFromDisk(for: faviconURL) {
                memoryCache.setObject(disk, forKey: faviconURL.absoluteString as NSString)
                resolvedPadImages[pad.id] = disk
                resolvedPadURLs[pad.id] = faviconURL
                return disk
            }
        }
        return nil
    }

    public func cancelLoad(for padID: UUID) {
        activeTasks[padID]?.cancel()
        activeTasks.removeValue(forKey: padID)
    }

    public func removePadState(for padID: UUID) {
        cancelLoad(for: padID)
        resolvedPadImages.removeValue(forKey: padID)
        resolvedPadURLs.removeValue(forKey: padID)
    }

    public func resolveBestIcon(
        for padID: UUID,
        candidates: [FaviconCandidate],
        onWinningURLResolved: @escaping @MainActor (URL) -> Void
    ) {
        guard !candidates.isEmpty else { return }

        // Fast-path: if top candidate is already resolved for this pad, skip refetching
        if let top = candidates.first,
           resolvedPadURLs[padID] == top.url,
           resolvedPadImages[padID] != nil {
            return
        }

        // Cancel any stale in-flight favicon task for this pad
        activeTasks[padID]?.cancel()

        let session = self.urlSession
        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            var bestFallbackSmall: (URL, NSImage)?

            for candidate in candidates.prefix(5) {
                if Task.isCancelled { return }

                if let cached = self.cachedImage(for: candidate.url) {
                    let maxPx = Self.maxPixelSide(of: cached)
                    if maxPx >= 48 || candidate.isScalableVector {
                        self.commitResolved(padID: padID, url: candidate.url, image: cached)
                        onWinningURLResolved(candidate.url)
                        return
                    } else if bestFallbackSmall == nil && maxPx >= 12 {
                        bestFallbackSmall = (candidate.url, cached)
                    }
                    continue
                }

                guard let fetched = await Self.fetchImage(url: candidate.url, session: session) else {
                    continue
                }
                if Task.isCancelled { return }

                let maxPx = Self.maxPixelSide(of: fetched)
                guard maxPx >= 12 else { continue } // Reject 1x1 tracking pixels

                self.saveToCache(image: fetched, for: candidate.url)

                if maxPx >= 48 || candidate.isScalableVector {
                    self.commitResolved(padID: padID, url: candidate.url, image: fetched)
                    onWinningURLResolved(candidate.url)
                    return
                } else if bestFallbackSmall == nil {
                    bestFallbackSmall = (candidate.url, fetched)
                }
            }

            if !Task.isCancelled, let (fallbackURL, fallbackImg) = bestFallbackSmall {
                self.commitResolved(padID: padID, url: fallbackURL, image: fallbackImg)
                onWinningURLResolved(fallbackURL)
            }
        }

        activeTasks[padID] = task
    }

    private func commitResolved(padID: UUID, url: URL, image: NSImage) {
        resolvedPadURLs[padID] = url
        resolvedPadImages[padID] = image
        activeTasks.removeValue(forKey: padID)
        revision &+= 1
    }

    private func cachedImage(for url: URL) -> NSImage? {
        let key = url.absoluteString as NSString
        if let mem = memoryCache.object(forKey: key) {
            return mem
        }
        if let disk = loadFromDisk(for: url) {
            memoryCache.setObject(disk, forKey: key)
            return disk
        }
        return nil
    }

    private func saveToCache(image: NSImage, for url: URL) {
        memoryCache.setObject(image, forKey: url.absoluteString as NSString)
        let fileURL = diskFileURL(for: url)
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let pngData = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: diskDirectoryURL, withIntermediateDirectories: true)
            try? pngData.write(to: fileURL, options: .atomic)
        }
    }

    private func loadFromDisk(for url: URL) -> NSImage? {
        let fileURL = diskFileURL(for: url)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = NSImage(data: data) else {
            return nil
        }
        return image
    }

    private func diskFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectoryURL.appendingPathComponent("\(hex).png", isDirectory: false)
    }

    private static func maxPixelSide(of image: NSImage) -> Int {
        var best = Int(max(image.size.width, image.size.height))
        for rep in image.representations {
            best = max(best, max(rep.pixelsWide, rep.pixelsHigh))
        }
        return best
    }

    private static func fetchImage(url: URL, session: URLSession) async -> NSImage? {
        if url.scheme?.lowercased() == "data" {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        }
        var request = URLRequest(url: url)
        request.setValue("image/svg+xml,image/png,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(UserAgentPreset.desktopSafari.resolvedUserAgent(), forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard !data.isEmpty, data.count <= 2_500_000 else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}
