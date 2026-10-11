# Superbike

SwiftUI iPhone safety research app with Swift 6 concurrency, adaptive on-device
YOLO detection, outdoor HUD, GPS/motion telemetry, speech/haptics, ReplayKit,
and a MapKit risk map. See `ARCHITECTURE.md` for the implementation rationale,
integration examples, hazard-data format and remaining production work.

## Run on your phone

1. Open `Superbike.xcodeproj` in Xcode.
2. Select Superbike → Signing & Capabilities → your development team.
3. Set a unique bundle identifier if Xcode requests it.
4. Connect and unlock the iPhone, approve Trust, and enable Developer Mode.
5. Choose the physical iPhone in Xcode and press Run. Requires iOS 17+.
6. Mount upright with the rear camera facing forward. Start stationary so the
   initial motion sample establishes the mount roll reference.

Portrait is deliberately locked so camera, FOV and overlay coordinates agree.
The model is bundled; inference runs offline. Map tiles may need network access.
Open Map before starting a ride to import sourced hazard JSON. No historical
incident database is bundled. An unmarked road does not imply a safe road.

## Source structure

```text
Superbike/
  SuperbikeApp.swift
  Models/       Sendable models and hazard validation
  Engine/       Camera queue, YOLO actor, risk estimator
  Telemetry/    Observable ride state, GPS actor, motion
  Alerts/       Speech and haptics
  Recording/    ReplayKit state and preview
  Views/        HUD, threat overlays, MapKit screen
Validation/     Deterministic algorithm and dataset checks
Vendor/         Local Ultralytics package and license
```

## Validation

Swift 6 physical-iPhone and simulator Debug builds and 12 deterministic
risk/dataset checks passed. The app launched in the simulator; the HUD and map
were visually inspected and the telemetry layer toggle was exercised. See
`HUD-preview.png`. These checks do not establish camera runtime or warning accuracy.

Run algorithm checks from this directory:

```sh
swiftc -swift-version 6 Superbike/Models/SafetyModels.swift Superbike/Models/HazardDataset.swift Superbike/Engine/RiskEngine.swift Validation/RiskEngineChecks.swift -o /tmp/superbike-risk-checks
/tmp/superbike-risk-checks
```

## Release status

Implemented and build-verified engineering prototype; not validated production
collision-avoidance software. Range, TTC and ride score are heuristic. Release
still needs mount calibration, annotated-video evaluation, physical-device energy
profiling, interruption/accessibility tests, persistence/privacy design, app icon
and distribution setup, and real incident data. Start testing stationary or
walking without staging collisions.

## Open source

[Ultralytics YOLO iOS](https://github.com/ultralytics/yolo-ios-app) supplies the
model and decoder under AGPL-3.0. See `Vendor/UltralyticsYOLO/LICENSE` and upstream
terms before distribution. Disclose dependencies and AI assistance in submissions.
The app uses Swift 6 complete concurrency checking; the vendor remains in its
upstream language mode. Local vendor changes remove redundant image annotation
and expose inference failure separately from a valid empty scene.
