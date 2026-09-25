import SwiftUI

/// The same mark is used during the entrance and throughout the conversation.
struct OrbView: View {
    var level: Double = 0
    var formed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                let size = geometry.size.width
                ZStack {
                    Circle().fill(Color(red: 0.88, green: 0.90, blue: 1))
                    ForEach(0..<5) { index in
                        Ellipse()
                            .fill(colors[index].gradient)
                            .frame(width: size * 0.75, height: size * 0.7)
                            .blur(radius: size * 0.14)
                            .offset(x: sin(time * 0.6 + Double(index) * 1.3) * size * 0.24,
                                    y: cos(time * 0.5 + Double(index)) * size * 0.23)
                            .rotationEffect(.degrees(Double(index) * 72 + time * 9))
                    }
                    Circle().fill(.radialGradient(colors: [.white.opacity(0.7), .clear],
                                                  center: .topLeading, startRadius: 0, endRadius: size * 0.8))
                    Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1)
                }
                .clipShape(Circle())
                .scaleEffect(formed ? 1 + min(level, 1) * 0.12 : 0.28)
                .rotationEffect(.degrees(formed ? 0 : -100))
                .shadow(color: Color.indigo.opacity(0.15), radius: size * 0.18, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
    }

    private let colors: [Color] = [
        Color(red: 0.43, green: 0.38, blue: 0.95),
        Color(red: 0.72, green: 0.69, blue: 1),
        Color(red: 0.43, green: 0.74, blue: 0.95),
        Color(red: 0.95, green: 0.70, blue: 0.79),
        Color(red: 0.48, green: 0.43, blue: 0.90)
    ]
}
