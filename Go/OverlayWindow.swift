//
//  OverlayWindow.swift
//  Go
//
//  The transparent, click-through overlay that draws the blue cursor, its
//  bubbles and highlights. One overlay window per screen.
//

import AppKit
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Transparent and click-through.
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Stay visible even when Go isn't the active app.
        self.hidesOnDeactivate = false

        self.setFrame(screen.frame, display: true)

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Never take focus.
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// The cursor-like triangle.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// Reports the bubble's measured size.
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Following the mouse, flying to a target, or pointing at it.
nonisolated enum CursorNavigationMode {
    case followingCursor
    case navigatingToTarget
    case pointingAtTarget
}

// The blue cursor for one screen. It shows only while the mouse is on this
// screen, and turns into a waveform (listening) or spinner (processing).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var goController: GoController

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, goController: GoController) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.goController = goController

        // Seed the position so the cursor doesn't flash at (0, 0).
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Navigation state

    @State private var cursorNavigationMode: CursorNavigationMode = .followingCursor

    /// -35° looks like a pointer; it turns to face the direction of flight.
    @State private var triangleRotationDegrees: Double = -35.0

    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// Where the mouse was when navigation started, to detect the user moving it.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Drives the frame-by-frame flight.
    @State private var navigationAnimationTimer: Timer?

    /// Grows to about 1.3x mid-flight and back to 1.0 on landing.
    @State private var cursorFlightScale: CGFloat = 1.0

    /// Pop-in scale for the pointing bubble.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True while flying back; only then does moving the mouse cancel the flight.
    @State private var isReturningToCursor: Bool = false

    private let fullWelcomeMessage = "Hi, I'm Go."

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps compositing).
            Color.black.opacity(0.001)

            // Welcome bubble (first launch only).
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // The push-to-talk prompt after the welcome.
            if isCursorOnThisScreen && goController.showOnboardingPrompt && !goController.onboardingPromptText.isEmpty {
                Text(goController.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(goController.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: goController.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // The walkthrough instruction, beside the cursor while it follows the mouse.
            if cursorNavigationMode == .followingCursor, cursorIsVisibleOnThisScreen,
               let guideText = goController.guideBubbleText, !guideText.isEmpty {
                let textSize = Self.guideBubbleTextSize(guideText)
                Text(guideText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(nil)
                    // Fixed width; height grows so no text is ever cut off.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: textSize.width, alignment: .topLeading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .position(guideBubbleCenter(textSize: textSize))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
            }
            // The pointing bubble, shown when the cursor reaches a target.
            if cursorNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    // Sized for the whole phrase so it doesn't reflow while typing out.
                    .frame(width: Self.guideBubbleTextSize(goController.detectedElementBubbleText ?? navigationBubbleText).width,
                           alignment: .topLeading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(guideBubbleCenter(textSize: Self.guideBubbleTextSize(navigationBubbleText)))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // The triangle, waveform and spinner stay in the view tree and cross-fade,
            // so nothing pops. While navigating, the flight timer sets the position
            // directly, so there is no implicit animation.
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + (cursorFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(cursorFlightScale)
                .opacity(cursorIsVisibleOnThisScreen && (goController.voiceState == .idle || goController.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    cursorNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: goController.voiceState)
                .animation(
                    cursorNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            BlueCursorWaveformView(audioPowerLevel: goController.currentAudioPowerLevel)
                .opacity(cursorIsVisibleOnThisScreen && goController.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: goController.voiceState)

            BlueCursorSpinnerView()
                .opacity(cursorIsVisibleOnThisScreen && goController.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: goController.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Welcome only on first appearance, on the screen with the mouse.
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: goController.detectedElementScreenLocation) { _, newLocation in
            if newLocation == nil {
                if cursorNavigationMode != .followingCursor { cancelNavigationAndResumeFollowing() }
                return
            }
            // Fly to a newly detected target.
            guard let screenLocation = newLocation,
                  let displayFrame = goController.detectedElementDisplayFrame else {
                return
            }

            // Only if the target is on this screen.
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Bubble size for guide text, measured with AppKit (SwiftUI's ideal size
    /// clipped long lines). Long text gets a wider bubble, up to 360 pt.
    static func guideBubbleTextSize(_ text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        func measure(_ width: CGFloat) -> CGRect {
            (text as NSString).boundingRect(with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        }
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var bounds = measure(240)
        for width in [300, 360] as [CGFloat] where bounds.height > lineHeight * 4.5 { bounds = measure(width) }
        return CGSize(width: ceil(bounds.width) + 3, height: ceil(bounds.height) + 4)
    }
    /// Beside the cursor, flipped near screen edges so it's never cut off.
    private func guideBubbleCenter(textSize: CGSize) -> CGPoint {
        let width = textSize.width + 16, height = textSize.height + 8
        var x = cursorPosition.x + 10 + width / 2
        if x + width / 2 > screenFrame.width - 6 { x = cursorPosition.x - 14 - width / 2 }
        var y = cursorPosition.y + 10 + height / 2
        if y + height / 2 > screenFrame.height - 6 { y = cursorPosition.y - 14 - height / 2 }
        return CGPoint(x: min(max(x, width / 2 + 6), screenFrame.width - width / 2 - 6),
                       y: min(max(y, height / 2 + 6), screenFrame.height - height / 2 - 6))
    }
    private var cursorIsVisibleOnThisScreen: Bool {
        switch cursorNavigationMode {
        case .followingCursor:
            // Another screen is navigating: hide this one so only one cursor shows.
            if goController.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // Flights and pointing finish uninterrupted; only the return flight can be
            // cancelled by moving the mouse.
            if self.cursorNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            if self.cursorNavigationMode != .followingCursor {
                return
            }

            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let cursorX = swiftUIPosition.x + 35
            let cursorY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: cursorX, y: cursorY)
        }
    }

    /// AppKit screen point (bottom-left) to this overlay's SwiftUI coordinates.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element navigation

    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt the welcome.
        guard !showWelcome || welcomeText.isEmpty else { return }

        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Sit just beside the element, not on top of it.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        cursorNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.cursorNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Flies along a quadratic bezier arc, turning to face the direction of travel.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Duration scales with distance, clamped to 0.6-1.4 s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // The control point is raised so the path arcs upward.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.cursorFlightScale = 1.0
                onComplete()
                return
            }

            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep ease-in-out.
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: (1-t)²·P0 + 2(1-t)t·P1 + t²·P2.
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Face the tangent: B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1).
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° because the triangle's tip points up at 0°.
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            let scalePulse = sin(linearProgress * .pi)
            self.cursorFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Shows the pointing bubble, typing the text out.
    private func startPointingAtElement() {
        cursorNavigationMode = .pointingAtTarget

        triangleRotationDegrees = -35.0

        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // The controller's text, else a short generic phrase.
        let pointerPhrase = goController.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // Hold for 3 seconds, then fly back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.cursorNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.cursorNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Types the bubble out one character at a time (30-60 ms each).
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard cursorNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        cursorNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels navigation because the user moved the mouse.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        cursorFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        cursorNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        cursorFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        goController.clearDetectedElementLocation()
    }

    // MARK: - Welcome

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    self.goController.startOnboardingPrompt()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Waveform

/// Replaces the triangle while push-to-talk is held.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Spinner

/// Replaces the triangle while Go works out its answer.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Creates one overlay window per screen.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], goController: GoController) {
        hideOverlay()

        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                goController: goController
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades the overlay windows out, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }
}

/// The harness's `highlight`: one outline at a time on its own click-through
/// window. A new highlight replaces the previous one.
enum ElementHighlightOverlay {
    static func hide() {
        generation += 1
        window?.orderOut(nil)
        window = nil
    }
    private static var window: OverlayWindow?
    private static var generation = 0

    static func show(_ rectInAppKitCoordinates: CGRect, label: String?, onScreenAt screenIndex: Int, seconds: Double) {
        window?.orderOut(nil)
        window = nil
        generation += 1
        guard NSScreen.screens.indices.contains(screenIndex) else { return }
        let screen = NSScreen.screens[screenIndex]
        let overlay = OverlayWindow(screen: screen)
        overlay.contentView = NSHostingView(rootView: ElementHighlightView(
            rect: rectInAppKitCoordinates, screenFrame: screen.frame, label: label
        ))
        overlay.orderFrontRegardless()
        window = overlay
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard generation == shown else { return }
            window?.orderOut(nil)
            window = nil
        }
    }
}

private struct ElementHighlightView: View {
    let rect: CGRect
    let screenFrame: CGRect
    let label: String?

    var body: some View {
        // SwiftUI's y grows downward, so the rect is flipped within the screen.
        let top = screenFrame.height - (rect.maxY - screenFrame.origin.y)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.cyan, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX - screenFrame.origin.x, y: top + rect.height / 2)
            if let label {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cyan)
                    .fixedSize()
                    .position(x: rect.midX - screenFrame.origin.x, y: max(top - 12, 12))
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
