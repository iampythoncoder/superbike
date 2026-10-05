# Integrated build — October 4, 2026

## What was wrong with the earlier demo

- The camera and GPS were gated on Start ride. No GPS origin was available for
  pre-ride routing and the camera initially showed a black area.
- A 2m GPS distance filter plus a five-second freshness timeout could label
  stationary reception unavailable. Invalid speed was replaced by zero.
- The map had only manually imported geometry; no automatic crash feed or entry
  alert path existed. Route display was only a recorded breadcrumb trail.
- There was no selfie-camera capture or rear-threat processing.
- ReplayKit recorded the screen, not independent camera video.
- Background/inactive handling could stop setup when a permission sheet appeared.
- There was no destination navigation or persistent ride library.

## Changes

`RideMonitor` now connects GPS, motion and preview independently from ride
tracking. It separates GPS validity from speed validity, feeds accepted fixes to
navigation and hazards, and keeps both cameras active when switching app panels.
Only backgrounding pauses sensors; temporary inactivity during permissions does
not cancel setup. A monotonic ride epoch prevents late GPS tasks resetting a new
ride. Camera generation tokens discard outputs across ride/lifecycle transitions.

`TelemetryFilter` validates location/velocity accuracy, timestamps and plausible
displacement. It distinguishes coarse position from usable route fixes, supports
bounded coordinate-derived speed when velocity is unavailable, and avoids
stationary distance growth. The map now recenters on full coordinate changes,
including purely east/west travel.

`CameraPipeline` uses explicit MultiCam inputs/output/preview connections,
portrait capture and no selfie mirroring. Supported formats and hardware budget
are checked. Frames are shared through a bounded ownership wrapper; one global
inference runs at a time with fair sharing between available feeds. Independent
RiskEngine instances prevent cross-camera tracking contamination. Capture and
inference budgets respond to thermal/system pressure; interrupted recording is
finalized. Road-only availability is explicit when MultiCam fails.

`CameraVideoRecorder` writes actual camera samples through AVAssetWriter to
separate road/rear MP4 segments. Only finalized MP4 files enter the library.
In-progress files retain a separate suffix; already finalized files survive an
interruption. 60-second segments and a 200MB free-space guard bound loss/storage
risk; this is not an auto-overwriting loop recorder. There is no audio capture.

`NavigationCoordinator` implements cancellable place search/directions, route
matching, maneuver cues, distance/ETA, sustained off-route detection/recalculation
and arrival. It checks the actual transport type returned by MapKit. A live test
found cycling requests returning a driving route; these are rejected. Walking
is an explicit alternative, not an automatic cycling fallback.

`HazardService` fetches official NYC bicycle injury/fatality history, clusters
records, persists cache and publishes coverage/freshness. Entry alerts use GPS
accuracy, speed-aware approach distance, heading checks, cooldown and exit
hysteresis. Imported zones combine with fetched zones. Outside supported
coverage the map explicitly reports unavailable data. Criteria/counts/date ranges
and source URLs are retained in provider details; no invented incidents are used.

`AlertCoordinator` prioritizes danger over historical and navigation speech and
uses side-specific messages. The main screen combines speed, two previews, threat
boxes, recording, ride controls and navigation; settings expose sensor readiness
and a real alert test. Local ride summaries and routes persist across launches.

## Verification and remaining acceptance

Physical-iPhone and simulator Swift 6 builds passed. All 66 deterministic checks
passed: 8 GPS, 12 risk/schema, 19 navigation and 27 hazard decoding, geometry,
clustering, entry/cooldown, cache and coverage checks. The simulator app launched
and accepted a controlled 5 m/s GPS route: its speed display correctly showed
11 mph with a valid GPS fix. `GPS-test-preview.png` records this simulated test,
not a physical ride. The temporary test route was cleared afterward. Public
place search and official NYC API responses were also exercised.

No physical iPhone is currently available through Xcode (only an unavailable old
device entry). Hence camera hardware, rear visibility, haptic feel, live GPS and
dual-video endurance have not been verified on the user's iPhone 15 Pro. Do not
represent the app as field-validated or universally covered. Test on-device and
capture any error status from Settings → Live sensor status.

## Install acceptance checklist

1. Grant precise location/camera. Verify stationary speed resolves to 0 (or an
   explicit unavailable state) and both physical previews align with their boxes.
2. Walk a known route; confirm speed and distance, search a destination and verify
   the displayed route type. Follow a safe pedestrian test route to verify cues.
3. Run Test sound & vibration. Verify road/behind labels and location permissions.
4. Record longer than 60 seconds; stop and play/share both saved camera clips.
5. Background/resume, deny/re-enable a permission and interrupt with a call;
   confirm visible paused/unavailable state and saved completed clips.
6. Check sourced NYC or imported high-crash-zone approach/entry/exit alerts using
   controlled test coordinates, not by seeking a dangerous road situation.
7. Profile a sustained ride for heat, battery, false alerts and missed detections.
