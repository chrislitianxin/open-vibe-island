import SwiftUI
import OpenIslandCore

/// Pixel-art session mascot. Running sessions shuffle their feet, sessions
/// waiting on the user blink, and finished sessions sit still with a glow.
struct PixelAgentGlyph: View {
    enum Mood: Equatable {
        case running
        case waiting
        case done
        case idle
    }

    let tint: Color
    let mood: Mood
    var pixel: CGFloat = 2

    private static let body: [String] = [
        ".######.",
        "########",
        "##.##.##",
        "########",
        "########",
    ]

    private static let feetA = ".#.##.#."
    private static let feetB = "#.#..#.#"

    var body: some View {
        if let interval = frameInterval {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / interval)
                sprite(tick: tick)
            }
        } else {
            sprite(tick: 0)
        }
    }

    private var frameInterval: TimeInterval? {
        switch mood {
        case .running: 0.28
        case .waiting: 0.45
        case .done, .idle: nil
        }
    }

    private func sprite(tick: Int) -> some View {
        let rows = rows(tick: tick)
        let width = CGFloat(rows[0].count) * pixel
        let height = CGFloat(rows.count) * pixel
        return Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "#" {
                    let rect = CGRect(
                        x: CGFloat(x) * pixel,
                        y: CGFloat(y) * pixel,
                        width: pixel,
                        height: pixel
                    )
                    context.fill(Path(rect), with: .color(tint))
                }
            }
        }
        .frame(width: width, height: height)
        .shadow(color: tint.opacity(glowOpacity), radius: 3)
        .opacity(mood == .idle ? 0.55 : 1)
    }

    private func rows(tick: Int) -> [[Character]] {
        var rows = Self.body
        if mood == .waiting, tick % 4 == 0 {
            rows[2] = "########"
        }
        rows.append(mood == .running && tick % 2 == 1 ? Self.feetB : Self.feetA)
        return rows.map(Array.init)
    }

    private var glowOpacity: Double {
        switch mood {
        case .running, .waiting: 0.45
        case .done: 0.35
        case .idle: 0
        }
    }
}

extension PixelAgentGlyph.Mood {
    init(phase: SessionPhase, presence: IslandSessionPresence) {
        switch phase {
        case .waitingForApproval, .waitingForAnswer:
            self = .waiting
        case .running:
            self = presence == .running ? .running : .idle
        case .completed:
            self = presence == .inactive ? .idle : .done
        }
    }
}
