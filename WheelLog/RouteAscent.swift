import Foundation

struct RouteAscent {
    private var recent = [Double]()
    private var anchor: Double?
    private var lastTime: Date?
    private(set) var gain: Double?

    mutating func add(altitude: Double, accuracy: Double, at time: Date) {
        guard altitude.isFinite, (0...20).contains(accuracy) else { return }
        if let lastTime, time.timeIntervalSince(lastTime) > 25 {
            recent.removeAll()
            anchor = nil
        }
        lastTime = time
        recent.append(altitude)
        if recent.count > 3 { recent.removeFirst() }
        guard recent.count == 3 else { return }
        // A median filters isolated GPS spikes. The anchor tracks climbs and descents.
        let filtered = recent.sorted()[1]
        guard let anchor else {
            self.anchor = filtered
            if gain == nil { gain = 0 }
            return
        }
        let change = filtered - anchor
        guard abs(change) >= max(3, accuracy * 0.45) else { return }
        if change > 0 { gain = (gain ?? 0) + change }
        self.anchor = filtered
    }
}
