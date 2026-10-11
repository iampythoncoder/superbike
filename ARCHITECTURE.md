# Superbike architecture and implementation

> Historical design notes for the September 30 prototype. The October 4
> integrated build replaces ReplayKit with separate camera MP4 recording and adds
> dual cameras, continuous GPS, navigation, real hazard data and persistent history.
> See `README.md` and `RELEASE-NOTES.md` for the current architecture and behavior.

## Refactoring decisions

The previous prototype evaluated risk and motion on the main actor and used the
vendor camera UI without a bounded inference cadence. The new ownership flow is:

```text
AVFoundation serial queue → one owned image → VisionWorker actor
                                               YOLO → RiskEngine
                                                        ↓ Sendable values
GPS → TelemetryWorker actor → RideMonitor (@MainActor @Observable)
Core Motion background queue → numeric sample ↗          ↓
                                                HUD / map / alerts
ReplayKit → main-actor recorder state → preview
```

1. `Models/` defines Sendable rectangles, motion, location, threats and hazard data.
2. `Engine/CameraPipeline.swift` confines capture configuration, frame callbacks,
   cadence and busy state to one serial queue. It discards late capture frames.
3. `Engine/VisionWorker.swift` owns one YOLO instance and RiskEngine. Inference,
   decoding and scoring execute without suspension and publish only value types.
4. `Telemetry/TelemetryWorker.swift` validates GPS and accumulates distance off
   the main actor. Motion uses a background serial OperationQueue; only numeric
   values cross back to UI, never CMDeviceMotion or CLLocation objects.
5. `Telemetry/RideMonitor.swift` owns observable UI state and ride generation.
   Old-generation and stale inference outputs are rejected. Main-actor work is
   limited to publication, lifecycle and UI-bound services.
6. `Alerts/` rate-limits reusable haptics and speech. `Recording/` guards ReplayKit
   transitions independently. `Views/` contains the HUD and risk map.

## Swift 6 and Ultralytics integration

The app target enables Swift 6 and complete concurrency checking. The vendor is
compiled in its upstream language mode and contains unchecked Sendable types.
Compiler acceptance does not authorize arbitrary concurrent use of that package.
Keep the single-owner adapter when extending this implementation.

`VisionWorker.prepare()` retains YOLO during asynchronous loading because the
upstream loader captures the instance weakly. A throwing continuation bridges
completion. Thresholds are set only after loading completes, inside the actor.
The pipeline guards preparation so only one attempt is active.

```swift
// Inside the actor, with a successfully loaded, privately owned model:
let result = model(frame.image)
let samples = result.boxes.map {
    DetectionSample(label: $0.cls, confidence: Double($0.conf), rect: $0.xywhn)
}
// Score here; pass ThreatSnapshot to the main actor, not YOLOResult or predictor.
```

The complete implementation is in `Engine/VisionWorker.swift`. A busy gate is set
before creating the inference task and cleared only after output delivery. This
prevents a task per camera frame from building an unbounded inference backlog.

Two explicit unchecked boundaries are documented in source:

- `VisionFrame` contains an owned immutable CGImage, timestamp and FOV. Its backing
  image is never mutated after transfer. Capture buffers are not queued to actors.
- `CameraPipeline` confines mutable state to its queue. Its session is bound to
  the UIKit preview on the main actor; configuration/start/stop remain on the queue.
  Output/status closures deliver Sendable values and weakly capture RideMonitor.

Ending a ride cancels its timer and stops capture/location/motion. Backgrounding
pauses the sensors. A generation token rejects late results from a prior ride.
The model remains cached between rides. Do not share it with another view/task.

Vendor changes are intentionally small: ObjectDetector no longer rasterizes an
annotated UIImage for every prediction, because SwiftUI draws the boxes. A new
`inferenceSucceeded` flag distinguishes failure from a valid empty result. Preserve
these changes on upgrades; upstream license headers remain intact.

## Thermal and battery budget

| Condition | Maximum detection rate |
| --- | ---: |
| Nominal; speed ≤ 5 m/s | 10 FPS |
| Nominal; speed > 5 m/s | 20 FPS |
| Fair thermal state | 12 FPS |
| Low Power Mode or recording | 10 FPS |
| Serious thermal state | 5 FPS |
| Critical thermal state | Capture/inference stopped; recording stop requested |

The most restrictive applicable cap wins. Budget refresh is 4 Hz. One in-flight
inference remains the hard limit. Actual FPS may be lower than the cap. Preview
capture uses 720p and the cadence gate runs before input copying. ReplayKit and
the display still consume energy; these changes are not proof against overheating.
Profile prolonged operation in sun, while charging and in insulating mounts.

## Risk and distance equations

Inputs are normalized rectangles with an upright top-left origin. Invalid or
nonfinite geometry, low confidence, unsupported classes and out-of-range boxes
are rejected. Class-constrained matching uses center and relative-size gates,
allows one match per track, and expires tracks after 0.6 seconds. This lightweight
tracker may still swap IDs during close crossings or heavy occlusion.

Nominal heights are person 1.7 m, car 1.5 m, bus 3.2 m, truck 3.0 m, bicycle 1.4 m
and motorcycle 1.3 m. Configuration permits changing these priors.

```text
estimated range = nominal height / [2 × normalized box height × tan(vertical FOV/2)]
expansion rate  = d(log(box height)) / dt
estimated TTC   = 1 / smoothed positive expansion rate
```

These are approximations, not measured object distances. Native horizontal FOV
becomes vertical after portrait rotation. Active-format FOV comes from the fixed
rear wide-angle lens; zoom and electronic stabilization are not enabled. The
HUD applies the same aspect-fill center crop as the preview. Alignment must still
be physically verified. Class size, posture, slope and orientation affect range.

TTC requires four observations and at least 0.35 s of track history. Smoothing uses
a 0.35 s time constant and a monotonic clock. Clipped objects do not produce TTC
or distance. Fresh motion suppresses TTC above 0.8 rad/s rotation, 0.55 g user
acceleration, or 0.45 rad roll relative to the starting mount pose. Missing motion
does not establish stability; evaluate that failure condition on device.

A tapered corridor plus short lateral-motion projection gates warnings. TTC below
4 s produces caution; below 2 s produces danger. Known ride speed adds up to 1 s
of margin. A close-range size/ego-speed prior alone may produce caution, never
danger. A 0.8 s downgrade delay reduces flapping. Severity outranks numeric score.
Neither score nor detector confidence is a calibrated collision probability.

Do not compute TTC as distance divided by GPS speed for moving targets: GPS speed
is ego speed, not closing speed. Optical expansion avoids that particular mistake
but remains sensitive to camera motion, shape changes and imperfect tracking.

The HUD says “No conflict detected,” not that a path is guaranteed safe. Results
older than 0.8 s are rejected. No valid result for 1 s marks vision unavailable and
removes stale boxes. Model failures have a separate unavailable state. GPS also
expires and shows a dash. Alert speech is short and rate limited; danger can
interrupt lower-priority speech. No periodic spoken “clear” reassurance is used.

## HUD and recording decisions

Material telemetry cards, high-contrast white text, monospaced numbers and
56–60 point controls support outdoor readability. Green/yellow/red boxes include
class text; status includes symbols and words. Threat color changes animate for
0.2 s except under Reduce Motion. Box positions update without interpolation lag.

ReplayKit is screen recording, including HUD/map, not a clean camera-only loop
buffer. Start/stop is guarded, including an end request while start permission is
pending. Unexpected stops reset recorder state. Preview precedes the ride summary.
Recording and preview interruption flows need physical-device validation.

The ride score is an event-count heuristic, clamped to 0–100. It penalizes warning,
danger and hard-motion events but is not normalized for exposure or route difficulty.
It should not be presented as a scientifically validated safety metric.

## Risk map and data integration

MapKit uses a light muted flat basemap with dark floating controls. Hazard circles
and wide corridor strokes are translucent red/orange; route is blue. The cyan
heading vector uses GPS course above 1.5 m/s and projects three seconds of travel,
clamped to 12–100 meters. Camera following distance increases with speed. Panning
turns follow off; the location control restores it. Map rotation is disabled so
the north-up vector retains its meaning.

Heatmap, Route and Telemetry toggle independently. The heat layer is translucent
hazard geometry, not a statistical density model. There is no bundled historical
dataset. The empty state says so. Model alerts are not automatically promoted to
public incident zones. Imported data stays in memory for this session.

While stopped, tap Map → Import to load JSON. Severity is 1 for caution, 2 for
danger; dates are ISO 8601. This schema example is illustrative, NOT actual data:

```json
{
  "zones": [{
    "id": "00000000-0000-0000-0000-000000000001",
    "center": { "latitude": 37.0, "longitude": -122.0 },
    "radiusMeters": 40,
    "severity": 2,
    "source": "ILLUSTRATIVE ONLY — replace with verified source",
    "observedAt": "2025-01-01T00:00:00Z"
  }],
  "corridors": []
}
```

Corridors have `id`, `points` (latitude/longitude array), `severity` and `source`.
Validation checks sizes, coordinate ranges, radii, duplicate IDs, source presence
and future dates. It does not verify source truthfulness. Production data needs
provenance, freshness, licensing and coverage management. No network or public
hazard write is performed by this importer.

## Verification and production gates

The deterministic harness covers stable boxes, physical approaches, camera shake,
class priors, invalid input, stable/reordered identities, invalid FOV and hazard
schema rejection. This checks implementation behavior, not field accuracy.

Before calling the app production-ready:

- Evaluate annotated rides across lighting, weather, motion, occlusion and mounts;
  measure sensitivity, false alerts/hour and latency percentiles by condition.
- Validate FOV/crop alignment and calibration on supported lenses/devices. Consider
  stronger tracking, ego-motion compensation or optional depth hardware.
- Profile sustained FPS, energy, memory and thermal transitions on iPhone 15 Pro
  and slower supported phones, with recording and bright display enabled.
- Test camera interruptions, incoming calls, denied/revoked permissions, missing
  GPS/motion, model failure, background/resume and ReplayKit preview dismissal.
- Complete Dynamic Type/VoiceOver/sunlight testing, privacy/retention and persistent
  history, incident-data operations, app icon and distribution signing.

Reference documentation:

- [Apple capture output](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput)
- [Apple MapKit for SwiftUI](https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui)
- [Ultralytics source and licensing](https://github.com/ultralytics/yolo-ios-app)

Complete Swift implementations live in the module files listed above. This is
an implemented engineering foundation; production safety performance requires
the device and field evidence described here.
