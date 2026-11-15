import CoreLocation
import MapKit
import Observation
import SwiftUI

/// Teleport: makes this device report a place of your choosing, in every app. The engine
/// holds the location through a developer connection, which only lasts while Nimbus runs,
/// so Nimbus asks to keep running in the background, as a navigation app does.
@MainActor @Observable
final class Teleport: NSObject, CLLocationManagerDelegate {
    static let shared = Teleport()

    enum State: Equatable {
        case off
        case moving
        case active
        case failed(String)
    }

    private(set) var state = State.off
    /// The place the device is held at, or about to be.
    private(set) var place: CLLocationCoordinate2D?
    private(set) var placeName: String?

    private let locations = CLLocationManager()
    private var watchdog: Task<Void, Never>?

    override init() {
        super.init()
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locations.distanceFilter = CLLocationDistanceMax
        locations.pausesLocationUpdatesAutomatically = false
    }

    var isActive: Bool { state == .active }

    /// Moves the device to a place.
    func go(to coordinate: CLLocationCoordinate2D, name: String?, udid: String) {
        guard state != .moving else { return }
        state = .moving
        place = coordinate
        placeName = name
        if locations.authorizationStatus == .notDetermined {
            locations.requestWhenInUseAuthorization()
        }
        Task {
            let error = await Self.teleport(udid: udid, to: coordinate)
            if let error {
                state = .failed(error)
                stayAwake(false)
            } else {
                state = .active
                stayAwake(true)
                watch(udid: udid)
            }
        }
    }

    /// Puts the device back on its real location.
    func stop() {
        watchdog?.cancel()
        watchdog = nil
        stayAwake(false)
        state = .off
        Task.detached { nimbus_teleport_stop() }
    }

    func dismissFailure() {
        if case .failed = state { state = .off }
    }

    private nonisolated static func teleport(udid: String, to coordinate: CLLocationCoordinate2D) async -> String? {
        await Task.detached {
            var error: UnsafeMutablePointer<CChar>?
            let succeeded = nimbus_teleport(udid, coordinate.latitude, coordinate.longitude, &error)
            guard !succeeded else { return nil }
            defer { nimbus_free_string(error) }
            return error.map { String(cString: $0) } ?? "Teleport didn't work."
        }.value
    }

    /// The connection can drop, when the VPN reconnects for one. Then the device is back on
    /// its real location, so Nimbus connects again and puts it back.
    private func watch(udid: String) {
        watchdog?.cancel()
        watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, state == .active, let place else { return }
                if nimbus_teleport_active() { continue }
                if let error = await Self.teleport(udid: udid, to: place) {
                    guard !Task.isCancelled else { return }
                    state = .failed("Lost the connection, so this device is back on its real location. \(error)")
                    stayAwake(false)
                    return
                }
            }
        }
    }

    /// Keeps Nimbus running in the background while the device is held at a place: iOS lets
    /// an app that follows the location keep running. The arrow in the status bar shows it.
    private func stayAwake(_ awake: Bool) {
        if awake {
            locations.allowsBackgroundLocationUpdates = true
            locations.showsBackgroundLocationIndicator = true
            locations.startUpdatingLocation()
        } else {
            locations.stopUpdatingLocation()
            locations.allowsBackgroundLocationUpdates = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.isActive { self.stayAwake(true) }
        }
    }

    /// Whether Nimbus may keep running in the background to hold the place.
    var canStayAwake: Bool {
        switch locations.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }
}

/// The Teleport tab: a map to pick a place, and a button to go there.
struct TeleportView: View {
    @Environment(PhoneModel.self) private var model
    @State private var teleport = Teleport.shared
    @State private var camera = MapCameraPosition.automatic
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedName: String?
    @State private var search = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        NavigationStack {
            MapReader { map in
                Map(position: $camera) {
                    if let target = picked ?? teleport.place {
                        Marker(pickedName ?? teleport.placeName ?? "Here", coordinate: target)
                    }
                }
                .onTapGesture { point in
                    if let coordinate = map.convert(point, from: .local) {
                        picked = coordinate
                        pickedName = nil
                        results = []
                    }
                }
            }
            .overlay(alignment: .top) { searchResults }
            .safeAreaInset(edge: .bottom) { panel }
            .navigationTitle("Teleport")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search for a place")
            .onSubmit(of: .search) { Task { await find() } }
            .onChange(of: search) { if search.isEmpty { results = [] } }
        }
    }

    @ViewBuilder private var searchResults: some View {
        if !results.isEmpty {
            List(results, id: \.self) { item in
                Button {
                    let coordinate = Self.coordinate(of: item)
                    picked = coordinate
                    pickedName = item.name
                    results = []
                    camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 4000, longitudinalMeters: 4000))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Place")
                        if let address = Self.address(of: item) {
                            Text(address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .listStyle(.plain)
            .frame(maxHeight: 280)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch teleport.state {
            case .active:
                Label("This device is in \(teleport.placeName ?? coordinateText(teleport.place))", systemImage: "location.fill")
                    .font(.headline)
                Text("Every app sees this place. Keep LocalDevVPN on and don't close Nimbus in the app switcher, or this device is back on its real location.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .onTapGesture { teleport.dismissFailure() }
            case .moving:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Moving this device…")
                }
            case .off:
                Text(picked == nil ? "Tap the map or search for a place." : (pickedName ?? coordinateText(picked)))
                    .font(.headline)
            }
            if (picked ?? teleport.place) == CLLocationCoordinate2D(latitude: 0, longitude: 0) {
                Text("Welcome to Null Island, where lost data ends up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if teleport.isActive {
                    Button("Back to Real Location", role: .destructive) { teleport.stop() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if let picked, picked != teleport.place || !teleport.isActive {
                    Button(teleport.isActive ? "Move Here" : "Teleport") {
                        guard case .connected(let device) = model.connection else { return }
                        teleport.go(to: picked, name: pickedName, udid: device.udid)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected || teleport.state == .moving)
                }
            }
            if !model.isConnected {
                Text("Turn on LocalDevVPN to teleport.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26, *) { return item.location.coordinate }
        return item.placemark.coordinate
    }

    private static func address(of item: MKMapItem) -> String? {
        if #available(iOS 26, *) { return item.address?.shortAddress }
        return item.placemark.title
    }

    private func coordinateText(_ coordinate: CLLocationCoordinate2D?) -> String {
        guard let coordinate else { return "" }
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    private func find() async {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        // Null Island: 0° N, 0° E, in the Atlantic. Mapmakers' joke about the place where
        // locations end up when something sets them to zero by mistake.
        if query.lowercased().replacingOccurrences(of: " ", with: "") == "nullisland" {
            let island = CLLocationCoordinate2D(latitude: 0, longitude: 0)
            results = []
            picked = island
            pickedName = "Null Island"
            camera = .region(MKCoordinateRegion(center: island, latitudinalMeters: 2_000_000, longitudinalMeters: 2_000_000))
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        results = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}
