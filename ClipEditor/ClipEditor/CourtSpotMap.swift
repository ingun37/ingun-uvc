import Foundation

private final class CourtSpotResource {}

struct CourtSpotMap: Decodable {
    struct Spot: Decodable {
        struct Location: Decodable {
            let x: Double
            let y: Double
        }

        let label: String
        let loc: Location
    }

    let spotList: [Spot]

    static func bundled() throws -> Self {
        guard let url = Bundle(for: CourtSpotResource.self)
            .url(forResource: "mapping", withExtension: "json") else {
            throw ShotEffectError.missingCourtSpotMap
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func nearestSpotIndex(to point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var nearest: (index: Int, squaredDistance: Double)?
        for (index, spot) in spotList.enumerated() {
            let label = spot.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, spot.loc.x.isFinite, spot.loc.y.isFinite else { continue }
            let dx = spot.loc.x - Double(point.x)
            let dy = spot.loc.y - Double(point.y)
            let squaredDistance = dx * dx + dy * dy
            if nearest == nil || squaredDistance < nearest!.squaredDistance {
                nearest = (index, squaredDistance)
            }
        }
        return nearest?.index
    }

    func label(at index: Int) -> String? {
        guard spotList.indices.contains(index) else { return nil }
        return spotList[index].label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nearestLabel(to point: CGPoint) -> String? {
        nearestSpotIndex(to: point).flatMap { label(at: $0) }
    }
}
