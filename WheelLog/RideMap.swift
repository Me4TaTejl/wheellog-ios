import MapKit
import SwiftUI

struct RideMap: View {
    let fixes: [RouteFix]
    let marker: RouteFix?
    var following = false
    @AppStorage("yandexTilesKey") private var key = ""

    var body: some View {
        RouteMapSurface(fixes: fixes, marker: marker, following: following, key: key)
            .overlay(alignment: .topLeading) {
                if !key.isEmpty {
                    Link(destination: URL(string: "https://yandex.ru/maps/")!) {
                        Image("YandexLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 96)
                    }
                    .accessibilityLabel("Открыть в Яндекс Картах")
                }
            }
    }
}

private struct RouteMapSurface: UIViewRepresentable {
    let fixes: [RouteFix]
    let marker: RouteFix?
    let following: Bool
    let key: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let state = context.coordinator
        if state.key != key {
            if let tiles = state.tiles { map.removeOverlay(tiles) }
            state.tiles = key.isEmpty ? nil : YandexTiles(key: key)
            if let tiles = state.tiles { map.addOverlay(tiles, level: .aboveRoads) }
            state.key = key
        }

        let changed = state.count != fixes.count || state.firstFix != fixes.first || state.lastFix != fixes.last
        if changed {
            let initial = state.count == 0 || state.firstFix != fixes.first
            if let line = state.line { map.removeOverlay(line) }
            state.line = nil
            state.count = fixes.count
            state.firstFix = fixes.first
            state.lastFix = fixes.last
            if fixes.count > 1 {
                let step = max(1, (fixes.count + 1_999) / 2_000)
                var points = stride(from: 0, to: fixes.count - 1, by: step).map { fixes[$0].coordinate }
                points.append(fixes[fixes.count - 1].coordinate)
                let line = MKPolyline(coordinates: points, count: points.count)
                state.line = line
                map.addOverlay(line, level: .aboveLabels)
            }
            if initial, let first = fixes.first {
                if let rect = state.line?.boundingMapRect, rect.width > 30 || rect.height > 30 {
                    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 40, bottom: 40, right: 40),
                                          animated: false)
                } else {
                    map.setRegion(.init(center: first.coordinate, latitudinalMeters: 650, longitudinalMeters: 650),
                                  animated: false)
                }
            }
        }

        if state.current != marker {
            if let marker {
                state.pin.coordinate = marker.coordinate
                if state.current == nil { map.addAnnotation(state.pin) }
            } else if state.current != nil {
                map.removeAnnotation(state.pin)
            }
            state.current = marker
            if following, let marker { map.setCenter(marker.coordinate, animated: !changed || state.count > 1) }
        }
        if following, !state.wasFollowing, let marker { map.setCenter(marker.coordinate, animated: true) }
        state.wasFollowing = following
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var key = ""
        var tiles: MKTileOverlay?
        var line: MKPolyline?
        var count = 0
        var firstFix: RouteFix?
        var lastFix: RouteFix?
        var current: RouteFix?
        var wasFollowing = false
        let pin = MKPointAnnotation()

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor(red: 0.91, green: 0.24, blue: 0.08, alpha: 1)
                renderer.lineWidth = 5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard (annotation as? MKPointAnnotation) === pin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "RidePosition")
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "RidePosition")
            view.annotation = annotation
            view.image = UIImage(systemName: "dot.circle.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold))?
                .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            view.displayPriority = .required
            view.isAccessibilityElement = true
            view.accessibilityLabel = "Положение на маршруте"
            return view
        }
    }
}

private final class YandexTiles: MKTileOverlay {
    private let key: String

    init(key: String) {
        self.key = key
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = 0
        maximumZ = 20
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "tiles.api-maps.yandex.ru"
        url.path = "/v1/tiles/"
        url.queryItems = [
            .init(name: "apikey", value: key),
            .init(name: "lang", value: "ru_RU"),
            .init(name: "x", value: String(path.x)),
            .init(name: "y", value: String(path.y)),
            .init(name: "z", value: String(path.z)),
            .init(name: "l", value: "map"),
            .init(name: "scale", value: String(min(2, max(1, Double(path.contentScaleFactor))))),
            .init(name: "projection", value: "web_mercator"),
            .init(name: "maptype", value: "map")
        ]
        return url.url!
    }
}
