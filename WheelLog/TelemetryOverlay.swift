import CoreGraphics
import CoreText
import Foundation
import UIKit

struct OverlaySample: Equatable {
    var telemetry = Telemetry()
    var demo = false
}

enum OverlayLayout {
    static let available: [Metric] = [.pwm, .power, .battery, .voltage, .temperature, .phaseCurrent]
    static let defaultMask = 0b000111

    static func metrics(for mask: Int) -> [Metric] {
        available.enumerated().compactMap { index, metric in
            mask & (1 << index) == 0 ? nil : metric
        }
    }

    static func draw(_ sample: OverlaySample, mask: Int, in size: CGSize, context: CGContext) {
        let scale = size.width / 360
        guard scale > 0, size.height / scale > 210 else { return }
        let height = size.height / scale
        let metrics = metrics(for: mask)
        let rowCount = (metrics.count + 2) / 3
        let panelHeight = CGFloat(86 + rowCount * 41)
        let top = height - panelHeight - 19
        let accent = CGColor(red: 0.84, green: 0.99, blue: 0.38, alpha: 1)
        let muted = CGColor(red: 0.75, green: 0.79, blue: 0.74, alpha: 1)
        let white = CGColor(gray: 1, alpha: 1)

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        let panel = CGRect(x: 14, y: top, width: 332, height: panelHeight)
        context.addPath(CGPath(roundedRect: panel, cornerWidth: 16, cornerHeight: 16, transform: nil))
        context.setFillColor(CGColor(red: 0.04, green: 0.06, blue: 0.05, alpha: 0.91))
        context.fillPath()

        let status: String
        if sample.demo { status = "ДЕМО" }
        else if sample.telemetry.speed == nil { status = "НЕТ ДАННЫХ" }
        else { status = "SHERMAN S" }
        write(status, at: CGPoint(x: 30, y: top + 22), size: 10, color: muted, in: context)
        let speedWidth = write(Metric.speed.display(sample.telemetry), at: CGPoint(x: 29, y: top + 63),
                               size: 39, color: accent, in: context)
        write(Metric.speed.unit, at: CGPoint(x: 36 + speedWidth, y: top + 62),
              size: 13, color: white, in: context)

        for (index, metric) in metrics.enumerated() {
            let column = CGFloat(index % 3)
            let row = CGFloat(index / 3)
            let x = 30 + column * 102
            let y = top + 87 + row * 41
            write(metric.rawValue.uppercased(), at: CGPoint(x: x, y: y), size: 9, color: muted, in: context)
            let mark = [.power, .battery].contains(metric) && !sample.demo && metric.value(in: sample.telemetry) != nil ? "≈" : ""
            let value = "\(mark)\(metric.display(sample.telemetry)) \(metric.unit)"
            write(value, at: CGPoint(x: x, y: y + 20), size: 15, color: white, in: context)
        }
        context.restoreGState()
    }

    @discardableResult
    private static func write(_ string: String, at point: CGPoint, size: CGFloat, color: CGColor,
                              in context: CGContext) -> CGFloat {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
