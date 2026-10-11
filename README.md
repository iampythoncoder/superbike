# Superbike — integrated iPhone build

## Install

Open `Superbike.xcodeproj` with Xcode 26.2+, choose your Apple development team in
Signing & Capabilities, connect your unlocked iPhone, and select it as the Run
destination. Enable Developer Mode and grant Camera and Precise Location access.
Minimum iOS is 17. Camera and haptic validation require a real phone.

## Use

1. Open the app: GPS and camera preview start immediately, before a ride.
2. Mount upright, back camera down the road. Check the selfie inset; your body
   must not obstruct any area you expect it to monitor behind you.
3. Search an address with the magnifying glass. Choose Cycling (where Apple
   returns a genuine cycling route) or explicitly choose Walking. Driving routes
   are rejected, never relabeled as bike routes. Preview on Navigate, then tap Go.
4. Start ride activates front/behind warnings and, by default, records both
   available cameras. Stop REC toggles recording without ending GPS/navigation.
5. Switch between Ride and Navigate. Camera detection and recording continue
   while navigating inside the app. Keep the app open and the screen unlocked.
6. End ride finalizes clips and stores the GPS track/summary. The video button
   opens Recordings & rides, with playback and share controls. Files are also in
   Files → On My iPhone → Superbike → Rides.

Settings include audio/haptic toggles, an alert test, automatic recording,
permission shortcuts and live sensor status. iOS permissions or calls may
interrupt capture; status is displayed rather than claiming protection is live.

## Implemented

- GPS starts independently from ride tracking, no 2m update suppression. Invalid
  speeds stay unknown, stale/poor fixes are labeled, implausible jumps rejected.
- Real simultaneous back-wide/selfie capture on supported MultiCam hardware,
  correctly aligned unmirrored previews and independent risk tracks. Explicit
  road-only fallback where dual capture is unavailable.
- Color-coded object boxes; side-specific spoken/haptic danger cues; adaptive
  total inference rate and capture frame-rate reduction under pressure.
- Camera MP4 recording, separate road/behind streams, 60-second segments, playback
  and sharing. No microphone audio. Stops below 200 MB free; no automatic deletion.
- Persistent ride history/GPS tracks; local storage only unless you share clips.
- Destination search, matching route-type verification, maneuver progress, ETA,
  off-route recalculation, arrival, spoken navigation cues and route display.
- Official NYC historical cyclist injury/fatality feed, local caching,
  high-crash clusters and entry/approach alerts. Coverage/source freshness visible.
- Sourced JSON hazard import for other regions; no false empty-map safety claim.

## Important coverage and device limits

Automatic historical crash coverage currently covers **NYC only**. Import a
verified dataset for other regions. A historical cluster is not a live crash.
The official feed can lag; the app displays its publication/cache status.

Apple cycling requests were observed returning an automobile route during live
testing. This build rejects that mismatch and explains unavailability. Explicit
walking routes remain available but are not bike routes; dismount where required.
Search/new directions and fresh map/data downloads need an internet connection.

The selfie camera cannot see through a rider, clothing or mount. Rear monitoring
means only its visible scene. Camera capture ends when the app backgrounds;
already recorded segments are retained. Resume starts camera preview, not an
unannounced new recording session.

These are implemented features, not a claim of validated collision avoidance.
The development Mac currently has no available connected iPhone, so physical
15 Pro camera alignment, warnings, GPS reception, thermal endurance and recording
must still be tested on that device. Begin stationary or walking without staged
collisions. Swift compilation and simulator tests do not prove field accuracy.

## Source and validation

See `RELEASE-NOTES.md` for this iteration and validation. Code lives under
`Superbike/{Engine,Telemetry,Navigation,Hazards,Views,Recording,Alerts,Models}`.
Independent deterministic harnesses are in `Validation/`.

Detection uses [Ultralytics YOLO iOS](https://github.com/ultralytics/yolo-ios-app)
and a bundled Core ML model under AGPL-3.0. Retain the vendor license and local
patches. Apple supplies maps/directions; NYC Open Data supplies historical crash
records. See provider source files for source URLs and clustering criteria.
