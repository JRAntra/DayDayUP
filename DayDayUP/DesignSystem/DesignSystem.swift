import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Color

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }

    /// A light/dark adaptive color that works back to macOS 12.
    static func adaptive(light: String, dark: String) -> Color {
        #if os(iOS)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
        #else
        return Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(Color(hex: dark)) : NSColor(Color(hex: light))
        })
        #endif
    }
}

/// DayDayUP's palette: grape as the house color, candy-bright signals for game moments.
enum Palette {
    static let grape = Color(hex: "6C4CF1")
    static let tangerine = Color(hex: "FF8A3D")   // streak flame
    static let mint = Color(hex: "22C48A")        // correct
    static let cherry = Color(hex: "FF4F6D")      // wrong, Review Book
    static let sunshine = Color(hex: "FFC93C")    // achievements

    static let ink = adaptiveInk
    static let background = Color.adaptive(light: "F5F2FF", dark: "17122B")
    static let surface = Color.adaptive(light: "FFFFFF", dark: "241D3F")
    static let surfaceSunken = Color.adaptive(light: "ECE7FB", dark: "1D1735")
    static let line = Color.adaptive(light: "DDD5F5", dark: "362D5C")

    private static let adaptiveInk = Color.adaptive(light: "2A2140", dark: "F3EFFF")

    /// The darker "ledge" under a chunky button.
    static func ledge(for color: Color) -> Color { color.opacity(0.55) }
}

// MARK: - Type

enum Typeface {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func label(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

// MARK: - Chunky button

/// The signature control: a candy-colored button standing on a darker ledge that it presses into.
struct ChunkyButtonStyle: ButtonStyle {
    var color: Color = Palette.grape
    var foreground: Color = .white
    var height: CGFloat = 50
    var fullWidth = true
    /// Overrides the ledge color, e.g. for light surface-colored buttons.
    var ledge: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        let depth: CGFloat = 5
        let pressed = configuration.isPressed
        return configuration.label
            .font(Typeface.title(17))
            .foregroundColor(foreground)
            .padding(.horizontal, 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color))
            .offset(y: pressed ? depth : 0)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(ledge ?? Palette.ledge(for: color))
                    .offset(y: depth)
            )
            .padding(.bottom, depth)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
    }
}

/// A quieter outlined variant for secondary actions.
struct OutlineChunkyButtonStyle: ButtonStyle {
    var color: Color = Palette.grape

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Typeface.title(16))
            .foregroundColor(color)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line, lineWidth: 2))
            .offset(y: pressed ? 3 : 0)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.line).offset(y: 3))
            .padding(.bottom, 3)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: - Card

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.line, lineWidth: 2))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }

    /// A minimum size for sheets on the Mac, where they'd otherwise open too small.
    /// On iPhone and iPad the sheet already fills the screen, and a fixed width would push it past the edges.
    @ViewBuilder func macSheetSize(minWidth: CGFloat, minHeight: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}

// MARK: - Progress ring

/// The review "coin": one segment per review on the ladder (1, 2, 4, 7, 15, 30 days).
/// New words are empty, each passed review fills a segment, remembered words get a check,
/// and the ring turns red while the word is in the Review Book.
struct ProgressRing: View {
    /// The word's ladder step (`WordMO.step`): 0 = New, 1–6 waiting, 7 = remembered.
    var step: Int
    var inReview: Bool
    var accent: Color
    var size: CGFloat = 26

    private var segments: Int { ReviewSchedule.reviewsToRemember }
    private var passed: Int { max(0, min(step, ReviewSchedule.rememberedStep) - 1) }
    private var color: Color { inReview ? Palette.cherry : accent }
    private var complete: Bool { step >= ReviewSchedule.rememberedStep && !inReview }

    var body: some View {
        let line = max(3, size * 0.15)
        let gap = 0.025
        ZStack {
            Circle().stroke(Palette.line, lineWidth: line)
            ForEach(0..<segments, id: \.self) { i in
                Circle()
                    .trim(from: CGFloat(i) / CGFloat(segments) + gap, to: CGFloat(i + 1) / CGFloat(segments) - gap)
                    .stroke(i < passed ? color : Color.clear, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if complete {
                Circle().fill(accent).padding(line * 0.9)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.38, weight: .black, design: .rounded))
                    .foregroundColor(.white)
            } else if inReview {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: size * 0.34, weight: .black))
                    .foregroundColor(Palette.cherry)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: step)
        .animation(.easeInOut(duration: 0.25), value: inReview)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if inReview { return "In the Review Book" }
        if complete { return "Remembered" }
        if step == 0 { return "New" }
        return "\(passed) of \(segments) reviews passed"
    }
}

// MARK: - Pair badge

struct PairBadge: View {
    var from: AppLanguage
    var to: AppLanguage
    var accent: Color
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: 2) {
            Text(from.badge)
            Image(systemName: "arrow.right").font(.system(size: size * 0.22, weight: .black))
            Text(to.badge)
        }
        .font(.system(size: size * 0.32, weight: .heavy, design: .rounded))
        .foregroundColor(.white)
        .padding(.horizontal, size * 0.22)
        .frame(height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(accent))
        .background(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(Palette.ledge(for: accent)).offset(y: 3))
    }
}

// MARK: - Streak flame

struct StreakFlame: View {
    var count: Int
    var lit: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .foregroundColor(lit ? Palette.tangerine : Palette.line)
            Text("\(count)")
                .font(Typeface.title(18))
                .foregroundColor(lit ? Palette.tangerine : Palette.ink.opacity(0.5))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count)-day streak\(lit ? ", today earned" : "")")
    }
}

// MARK: - Confetti

/// A short celebratory burst for "remembered" moments and achievements. Respects Reduce Motion.
struct ConfettiBurst: View {
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    private struct Piece {
        let x: CGFloat, delay: Double, speed: CGFloat, spin: Double, color: Color, width: CGFloat
    }

    private static let colors = [Palette.grape, Palette.tangerine, Palette.mint, Palette.cherry, Palette.sunshine, Color(hex: "1FA2FF")]
    @State private var pieces: [Piece] = []

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: startedAt == nil)) { timeline in
            Canvas { context, size in
                guard let startedAt else { return }
                let t = timeline.date.timeIntervalSince(startedAt)
                guard t < 2.2 else { return }
                for piece in pieces {
                    let local = max(0, t - piece.delay)
                    let y = -20 + CGFloat(local) * piece.speed + CGFloat(local * local) * 260
                    let x = piece.x * size.width + CGFloat(sin(local * 6 + piece.spin)) * 18
                    var copy = context
                    copy.opacity = max(0, 1 - local / 2)
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .degrees(piece.spin * 180 + local * 400))
                    copy.fill(Path(roundedRect: CGRect(x: -piece.width / 2, y: -4, width: piece.width, height: 8), cornerRadius: 2),
                              with: .color(piece.color))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _ in
            guard !reduceMotion else { return }
            pieces = (0..<70).map { _ in
                Piece(x: .random(in: 0...1), delay: .random(in: 0...0.25), speed: .random(in: 120...320),
                      spin: .random(in: 0...2), color: Self.colors.randomElement()!, width: .random(in: 6...12))
            }
            let start = Date()
            startedAt = start
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                if startedAt == start { startedAt = nil }
            }
        }
    }
}

// MARK: - Haptics

enum Haptics {
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
    static func error() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(Palette.grape.opacity(0.6))
            Text(title).font(Typeface.title(20)).foregroundColor(Palette.ink)
            Text(message)
                .font(Typeface.body(15))
                .foregroundColor(Palette.ink.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
