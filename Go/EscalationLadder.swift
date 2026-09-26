//
//  EscalationLadder.swift
//  Go
//
//  What the harness returns when a name did not resolve (`notFound` or
//  `ambiguous`): the smallest useful capture, the candidates inside it, and
//  for each a point that picks it out alone. The crop happens at capture
//  time, so it keeps full resolution.
//

import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

nonisolated enum EscalationLadder {

    /// Which rung answered. `none` (structure resolved it) is never returned.
    enum Tier: String, CaseIterable {
        case none
        case element
        case window
        case display
    }

    /// Context kept around a candidate so neighbours are visible.
    static let candidatePaddingInPoints: CGFloat = 24

    /// Maximum width or height of the returned image.
    static let maximumCaptureDimensionInPixels = 4096

    static let jpegCompressionFactor = 0.92

    static let maximumStoredImages = 10

    static let captureDeadlineInSeconds = 10.0

    // MARK: - Coordinate conversion

    /// AppKit global rect (bottom-left origin) to `SCStreamConfiguration.sourceRect`
    /// (top-left, relative to the display). Getting this wrong mirrors the crop
    /// vertically, so it is unit tested.
    static func sourceRect(
        forAppKitRect rect: CGRect,
        onDisplayWithAppKitFrame displayFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: rect.minX - displayFrame.minX,
            y: displayFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Region

    /// The union of candidate frames, padded. Zero-area frames are dropped.
    static func region(forCandidateFrames frames: [CGRect]) -> CGRect? {
        let usable = frames.filter { $0.width > 0 && $0.height > 0 }
        guard var union = usable.first else { return nil }
        for frame in usable.dropFirst() { union = union.union(frame) }
        return union.insetBy(dx: -candidatePaddingInPoints, dy: -candidatePaddingInPoints)
    }

    /// Indices of windows whose frames touch `region`, shared edges included
    /// (pixel rounding can still include them). Unreadable (zero) frames count too.
    static func windowIndices(intersecting region: CGRect, windowFrames: [CGRect]) -> [Int] {
        windowFrames.indices.filter { index in
            let frame = windowFrames[index]
            guard frame.width > 0, frame.height > 0 else { return true }
            let overlapsHorizontally = frame.minX <= region.maxX && frame.maxX >= region.minX
            let overlapsVertically = frame.minY <= region.maxY && frame.maxY >= region.minY
            return overlapsHorizontally && overlapsVertically
        }
    }

    // MARK: - Tier choice

    /// Which rung to take, with the condition that decided it.
    static func chooseTier(
        forcedTier: Tier?,
        candidateFrames: [CGRect],
        windowFrame: CGRect?,
        windowActionableCount: Int
    ) -> (tier: Tier, reason: String) {
        if let forcedTier {
            return (forcedTier, "the caller asked for the \(forcedTier.rawValue) tier")
        }

        if let candidateRegion = region(forCandidateFrames: candidateFrames) {
            return (.element, "\(candidateFrames.count) element(s) matched that name; the region is the union "
                + "of their frames padded \(Int(candidatePaddingInPoints)) pt "
                + "(\(Int(candidateRegion.width))x\(Int(candidateRegion.height)) pt)")
        }

        guard let windowFrame else {
            return (.display, "no element matched and there is no focused-window root node to crop to")
        }
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            return (.display, "no element matched and the focused window's frame has zero area")
        }
        guard windowActionableCount > 0 else {
            return (.display, "no element matched and the focused window publishes 0 actionable "
                + "descendants, so cropping to it would photograph a window nothing can be done in")
        }
        return (.window, "no element matched; the focused window is usable "
            + "(\(Int(windowFrame.width))x\(Int(windowFrame.height)) pt, \(windowActionableCount) actionable descendants)")
    }

    // MARK: - Separating point
    //
    // A suggested point is only returned if re-issuing with it would resolve
    // to exactly one candidate.

    /// Every cell the other frames cut this one into, nearest the centre first.
    /// The frames are axis-aligned, so cutting at every edge coordinate visits each
    /// cell once: if a separating point exists, one of these is it.
    static func searchPoints(in frame: CGRect, avoiding others: [CGRect]) -> [CGPoint] {
        func midpoints(from low: CGFloat, to high: CGFloat, cutAt cuts: [CGFloat]) -> [CGFloat] {
            var edges: [CGFloat] = [low, high]
            for cut in cuts where cut > low && cut < high {
                edges.append(cut)
            }
            edges.sort()
            var result: [CGFloat] = []
            var index = 0
            while index < edges.count - 1 {
                let midpoint: CGFloat = (edges[index] + edges[index + 1]) / 2
                result.append(midpoint)
                index += 1
            }
            return result
        }

        let xs = midpoints(from: frame.minX, to: frame.maxX,
                           cutAt: others.flatMap { [$0.minX, $0.maxX] })
        let ys = midpoints(from: frame.minY, to: frame.maxY,
                           cutAt: others.flatMap { [$0.minY, $0.maxY] })

        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var cells: [CGPoint] = []
        for y in ys { for x in xs { cells.append(CGPoint(x: x, y: y)) } }

        func squaredDistanceFromCentre(_ point: CGPoint) -> CGFloat {
            let dx: CGFloat = point.x - centre.x
            let dy: CGFloat = point.y - centre.y
            return dx * dx + dy * dy
        }
        cells.sort { squaredDistanceFromCentre($0) < squaredDistanceFromCentre($1) }
        return [centre] + cells
    }

    /// A point inside `frames[index]` and no other candidate, or nil. Never a
    /// "nearest" fallback.
    static func separatingPoint(forCandidateAt index: Int, among frames: [CGRect]) -> CGPoint? {
        guard frames.indices.contains(index) else { return nil }
        let frame = frames[index]
        guard frame.width > 0, frame.height > 0 else { return nil }

        let others = frames.enumerated().filter { $0.offset != index }.map(\.element)
        for point in searchPoints(in: frame, avoiding: others) where frame.contains(point) {
            if frames.filter({ $0.contains(point) }).count == 1 { return point }
        }
        return nil
    }

    // MARK: - Candidates

    /// Nodes whose name equals `title` (and role, if given): the same rule as the
    /// resolver, so these are exactly the ambiguous matches.
    static func namedCandidates(
        in rootNode: AccessibilityElementNode,
        title: String,
        role: String?
    ) -> [AccessibilityElementNode] {
        rootNode.flattenedDescendants().filter { node in
            node.displayName?.raw == title && (role == nil || node.role == role)
        }
    }

    // MARK: - Displays

    /// A display as AppKit describes it (read on main).
    struct DisplayInfo {
        let displayID: CGDirectDisplayID
        let appKitFrame: CGRect
        let backingScaleFactor: CGFloat
    }

    /// Hops to main when called from the request queue.
    static func displays() -> [DisplayInfo] {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { displays() } }
        return NSScreen.screens.compactMap { screen in
            guard let identifier = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return nil }
            return DisplayInfo(
                displayID: identifier,
                appKitFrame: screen.frame,
                backingScaleFactor: screen.backingScaleFactor
            )
        }
    }

    /// The display holding most of the region.
    static func display(holding region: CGRect, among displays: [DisplayInfo]) -> DisplayInfo? {
        if let index = ScreenCaptureUtility.bestDisplayIndex(
            for: region, among: displays.map(\.appKitFrame)
        ) {
            return displays[index]
        }
        return nil
    }

    /// Pixel size at the display's scale, shrunk to fit the cap.
    static func pixelSize(
        forRegion region: CGRect,
        backingScaleFactor: CGFloat
    ) -> (width: Int, height: Int) {
        let widthInPixels = region.width * backingScaleFactor
        let heightInPixels = region.height * backingScaleFactor
        let cap = CGFloat(maximumCaptureDimensionInPixels)
        let shrink = min(1.0, cap / max(widthInPixels, heightInPixels, 1))
        return (
            max(1, Int((widthInPixels * shrink).rounded())),
            max(1, Int((heightInPixels * shrink).rounded()))
        )
    }

    // MARK: - Inspection before capture

    /// Walks every window of `application` that touches `region`, as input to
    /// `ActionSafetyKernel.evaluateCapture`, just before the capture.
    static func inspectForCapture(region: CGRect, of application: NSRunningApplication) -> CaptureInspection {
        let read = AccessibilityWindows.liveWindows(for: application)
        guard read.readSucceeded else {
            return CaptureInspection(windowListReadError: read.error.rawValue)
        }
        let indices = windowIndices(
            intersecting: region,
            windowFrames: read.windows.map(\.candidate.frameInAppKitCoordinates)
        )
        return CaptureInspection(windows: indices.map { index -> CaptureInspection.WindowWalk in
            let window = read.windows[index]
            do {
                let snapshot = try AccessibilityTreeWalker.snapshotWindow(window.element, of: application)
                return CaptureInspection.WindowWalk(
                    title: window.candidate.title,
                    role: window.candidate.role,
                    nodes: snapshot.rootNode?.flattenedDescendants() ?? [],
                    stopReasons: snapshot.walkStopReasons,
                    subtreesLostToFailedReads: snapshot.subtreesLostToFailedReads
                )
            } catch {
                return CaptureInspection.WindowWalk(
                    title: window.candidate.title, role: window.candidate.role,
                    failure: String(describing: error)
                )
            }
        })
    }

    // MARK: - Capture

    struct CaptureOutcome {
        let jpeg: Data
        /// The request clipped to the display.
        let region: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let milliseconds: Int
    }

    enum CaptureFailure: Error, CustomStringConvertible {
        case noDisplay
        case regionOffScreen
        case captureFailed(String)
        case encodingFailed
        case timedOut
        case applicationNotListed(pid_t)
        case ownApplication

        var description: String {
            switch self {
            case .applicationNotListed(let processIdentifier):
                return "ScreenCaptureKit lists no application with process ID \(processIdentifier), and a "
                    + "display-wide capture is never the fallback — it would photograph windows the "
                    + "secure-field check did not inspect"
            case .ownApplication:
                return "the target application is Go itself, and the agent never photographs its own overlay"
            case .noDisplay: return "no display is available to capture"
            case .regionOffScreen: return "the region does not intersect any display"
            case .captureFailed(let detail): return "ScreenCaptureKit failed: \(detail)"
            case .encodingFailed: return "the captured image could not be encoded as JPEG"
            case .timedOut: return "the capture did not return within \(Int(captureDeadlineInSeconds))s"
            }
        }
    }

    /// Captures one region of one display, showing only the target app's windows
    /// (the app that was inspected). Other apps and Go's overlay are excluded.
    static func captureRegion(
        _ region: CGRect,
        on display: DisplayInfo,
        processIdentifier: pid_t
    ) async throws -> CaptureOutcome {
        let startedAt = Date()

        // Never photograph our own overlay.
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw CaptureFailure.ownApplication
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw CaptureFailure.captureFailed(String(describing: error))
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID })
                ?? content.displays.first else {
            throw CaptureFailure.noDisplay
        }

        let clipped = region.intersection(display.appKitFrame)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw CaptureFailure.regionOffScreen
        }

        // By pid: two instances of an app share a bundle id.
        guard let targetApplication = content.applications.first(where: {
            $0.processID == processIdentifier
        }) else {
            throw CaptureFailure.applicationNotListed(processIdentifier)
        }
        let filter = SCContentFilter(
            display: scDisplay, including: [targetApplication], exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect(
            forAppKitRect: clipped, onDisplayWithAppKitFrame: display.appKitFrame
        )
        let size = pixelSize(forRegion: clipped, backingScaleFactor: display.backingScaleFactor)
        configuration.width = size.width
        configuration.height = size.height

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } catch {
            throw CaptureFailure.captureFailed(String(describing: error))
        }

        guard let jpeg = NSBitmapImageRep(cgImage: image)
                .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionFactor]) else {
            throw CaptureFailure.encodingFailed
        }

        return CaptureOutcome(
            jpeg: jpeg,
            region: clipped,
            // Report what came back, not what was asked for.
            pixelWidth: image.width,
            pixelHeight: image.height,
            milliseconds: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    private final class OutcomeBox: @unchecked Sendable {
        var result: Result<CaptureOutcome, Error>?
    }

    /// Synchronous wrapper for ScreenCaptureKit, run on a detached task with a
    /// 10 s deadline so the harness can never hang on it.
    static func captureSynchronously(
        region: CGRect,
        on display: DisplayInfo,
        processIdentifier: pid_t
    ) -> Result<CaptureOutcome, Error> {
        let box = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            do {
                box.result = .success(try await captureRegion(
                    region, on: display, processIdentifier: processIdentifier
                ))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + captureDeadlineInSeconds) == .success,
              let result = box.result else {
            return .failure(CaptureFailure.timedOut)
        }
        return result
    }

    // MARK: - Storage

    /// Escalation images are written here and the response carries the path,
    /// keeping images out of audit lines.
    static var imageDirectory: URL {
        HarnessServer.supportDirectory.appendingPathComponent("escalation", isDirectory: true)
    }

    static func writeImage(_ data: Data) -> URL? {
        let timestamp = HarnessPolicy.auditTimestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = imageDirectory.appendingPathComponent("escalation-\(timestamp).jpg")
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        guard (try? data.write(to: url)) != nil else { return nil }
        pruneImages()
        return url
    }

    /// Keep the newest ten.
    static func pruneImages() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: imageDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let images = contents
            .filter { $0.lastPathComponent.hasPrefix("escalation-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard images.count > maximumStoredImages else { return }
        for stale in images.prefix(images.count - maximumStoredImages) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
