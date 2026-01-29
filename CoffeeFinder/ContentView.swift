import SwiftUI
import MapKit
import CoreLocation

// MARK: - Main View

struct ContentView: View {
    @StateObject private var vm = CoffeeFinderViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {

                // Search Controls
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Enter ZIP (optional)", text: $vm.zipCode)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)

                        Button("Use My Location") {
                            vm.useMyLocation()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 8) {
                        Button("Search Coffee") {
                            vm.searchCoffee()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isSearching)

                        Button("Clear") {
                            vm.clearResults()
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isSearching)
                    }

                    if let statusText = vm.statusText {
                        Text(statusText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                // Map
                Map(position: $vm.cameraPosition, selection: $vm.selectedPlaceID) {
                    UserAnnotation()

                    ForEach(vm.places) { place in
                        Marker(place.name, coordinate: place.coordinate)
                            .tag(place.id)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onChange(of: vm.selectedPlaceID) { _, newValue in
                    if let id = newValue, let place = vm.places.first(where: { $0.id == id }) {
                        vm.selectedPlace = place
                    }
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                if let selected = vm.selectedPlace {
                    SelectedPlaceCard(place: selected) {
                        vm.openDirections(to: selected)
                    }
                    .padding(.horizontal)
                }

                List(vm.places) { place in
                    Button {
                        vm.selectedPlace = place
                        vm.selectedPlaceID = place.id
                        vm.focusMap(on: place.coordinate)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.name)
                                .font(.headline)

                            if let address = place.addressLine {
                                Text(address)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Text(String(format: "%.1f miles away", place.distanceMiles))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Coffee Finder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.isSearching {
                        ProgressView()
                    }
                }
            }
            .onAppear {
                vm.requestLocationPermission()
            }
            .alert("Location Error", isPresented: $vm.showLocationAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(vm.locationAlertMessage ?? "Please enable location permissions in Settings.")
            }
        }
    }
}

// MARK: - Selected Place Card

struct SelectedPlaceCard: View {
    let place: CoffeePlace
    let onDirections: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(place.name)
                .font(.title3)
                .bold()

            if let address = place.addressLine {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(String(format: "%.1f miles away", place.distanceMiles))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Directions") {
                    onDirections()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - ViewModel

@MainActor
final class CoffeeFinderViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var zipCode: String = ""
    @Published var places: [CoffeePlace] = []
    @Published var selectedPlace: CoffeePlace?
    @Published var isSearching: Bool = false

    @Published var cameraPosition: MapCameraPosition = .automatic
    @Published var selectedPlaceID: UUID?

    @Published var statusText: String?
    @Published var showLocationAlert: Bool = false
    @Published var locationAlertMessage: String?

    private let locationManager = CLLocationManager()
    private var currentLocation: CLLocation?

    private let searchRadiusMeters: CLLocationDistance = 10 * 1609.344 // 10 miles

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocationPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func useMyLocation() {
        statusText = "Getting your location…"
        locationManager.requestLocation()
    }

    func clearResults() {
        places.removeAll()
        selectedPlace = nil
        selectedPlaceID = nil
        statusText = nil
    }

    func searchCoffee() {
        Task {
            isSearching = true
            defer { isSearching = false }

            do {
                let center: CLLocationCoordinate2D

                if !zipCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    statusText = "Geocoding ZIP \(zipCode)…"
                    center = try await geocode(zip: zipCode)
                } else if let loc = currentLocation {
                    center = loc.coordinate
                } else {
                    statusText = "No location yet — trying to fetch your location…"
                    locationManager.requestLocation()
                    try await Task.sleep(nanoseconds: 500_000_000)
                    guard let loc2 = currentLocation else {
                        statusText = "Enter a ZIP code or allow location access."
                        showLocationAlert(message: "Enter a ZIP code, or allow location access to search near you.")
                        return
                    }
                    center = loc2.coordinate
                }

                focusMap(on: center)

                statusText = "Searching coffee places within 10 miles…"
                let items = try await localSearchCoffee(near: center)

                let reference = currentLocation ?? CLLocation(latitude: center.latitude, longitude: center.longitude)

                let mapped: [CoffeePlace] = items.compactMap { item in
                    guard let coord = item.placemark.location?.coordinate else { return nil }
                    let distanceMeters = reference.distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                    let distanceMiles = distanceMeters / 1609.344
                    return CoffeePlace(
                        name: item.name ?? "Coffee Place",
                        coordinate: coord,
                        mapItem: item,
                        addressLine: item.placemark.compactAddress,
                        distanceMiles: distanceMiles
                    )
                }
                .filter { $0.distanceMiles <= 10.0 }
                .sorted { $0.distanceMiles < $1.distanceMiles }

                places = mapped
                selectedPlace = places.first
                selectedPlaceID = selectedPlace?.id

                if places.isEmpty {
                    statusText = "No coffee places found within 10 miles. Try another ZIP."
                } else {
                    statusText = "Found \(places.count) places."
                }

            } catch {
                statusText = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    func focusMap(on coordinate: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: searchRadiusMeters * 2,
            longitudinalMeters: searchRadiusMeters * 2
        )
        cameraPosition = .region(region)
    }

    func openDirections(to place: CoffeePlace) {
        let mapItem = place.mapItem
        mapItem.name = place.name
        let launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        mapItem.openInMaps(launchOptions: launchOptions)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            statusText = "Location enabled. Tap 'Use My Location' or search."
        case .denied, .restricted:
            statusText = "Location disabled. You can still search by ZIP."
        case .notDetermined:
            statusText = "Please allow location to search near you (or use ZIP)."
        @unknown default:
            statusText = "Unknown location status."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        currentLocation = latest

        if case .automatic = cameraPosition {
            focusMap(on: latest.coordinate)
        }

        statusText = "Location updated."
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        showLocationAlert(message: "Couldn’t get your location. Enter a ZIP code or enable location permissions.")
    }

    private func showLocationAlert(message: String) {
        locationAlertMessage = message
        showLocationAlert = true
    }

    // MARK: - Search Helpers

    private func geocode(zip: String) async throws -> CLLocationCoordinate2D {
        let cleaned = zip.trimmingCharacters(in: .whitespacesAndNewlines)
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.geocodeAddressString(cleaned)
        guard let coordinate = placemarks.first?.location?.coordinate else {
            throw NSError(domain: "Geocode", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid ZIP code"])
        }
        return coordinate
    }

    private func localSearchCoffee(near center: CLLocationCoordinate2D) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "coffee"
        request.region = MKCoordinateRegion(center: center,
                                            latitudinalMeters: searchRadiusMeters * 2,
                                            longitudinalMeters: searchRadiusMeters * 2)

        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        return response.mapItems
    }
}

// MARK: - Model

struct CoffeePlace: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let mapItem: MKMapItem
    let addressLine: String?
    let distanceMiles: Double
}

private extension MKPlacemark {
    var compactAddress: String? {
        let parts: [String?] = [
            subThoroughfare,
            thoroughfare,
            locality,
            administrativeArea,
            postalCode
        ]
        let joined = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }
}
