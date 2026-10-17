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
3. Search an address with the magnifying glass. Cycling uses the FOSSGIS / OSRM
   bicycle graph, including Cary, NC. Walking uses Apple Maps. Select a result,
   preview on Navigate, then tap Go. Neither option substitutes a driving route.
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

On Navigate, the **area/layers button** selects **All Cary**, **NC-02 · Ross
district**, **Cary + NC-02**, or **Near me · 3 km**. The local default is the
combined view. The full-area query is independent of the rider's location; GPS
updates do not shrink it back to a downtown radius. Purple outlines show Census
boundaries. Use “Show entire selected area” to zoom back out after panning.
Nearby GPS-based warnings continue independently of the displayed map area.

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
- Official North Carolina (including Cary) bicycle-crash and NYC cyclist-injury/fatality feeds, local caching,
  high-crash clusters and entry/approach alerts. Coverage/source freshness visible.
- Sourced JSON hazard import for other regions; no false empty-map safety claim.

## Important coverage and device limits

Automatic historical crash coverage includes **North Carolina (including Cary)**
through NCDOT's geocoded non-motorist crash layer (Bicyclist records only, five-year
query), and **NYC** through NYPD (three-year cyclist injury/fatality query). Import a
verified dataset for other regions. A historical cluster is not a live crash.
The official feed can lag; the app displays its publication/cache status.
Full Cary coverage follows Census BAS 2026 town limits, including disconnected
municipal areas. NC-02 follows the **current 119th Congress (2025–2027)** district
represented by Deborah Ross, not the prospective 120th Congress election map.
The combined view is the union of the two polygons. Area queries paginate the
official source and apply exact polygon filtering, with separate offline caches.

Cycling requests use the public FOSSGIS bicycle-routing service because Apple
cycling requests returned automobile routes in testing. The response's step modes
and endpoint distances are validated. FOSSGIS is a shared service with no uptime
guarantee; requests are limited to at most one per second and reroutes are rate
limited. It is suitable for light use; provision dedicated hosting before scaling.
Routes are not optimized against the historical crash overlay. Walking is a
separate option; dismount where required. Search/new directions and fresh map/data
downloads need an internet connection. Route endpoints go to FOSSGIS, place search
and walking directions go to Apple, and crash queries go to the official source.
Attribution, source dates and links are available under Map → Sources & coverage.

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

See `CARY-NAVIGATION-FIX.md` for the local data source, fix details and verification.

Detection uses [Ultralytics YOLO iOS](https://github.com/ultralytics/yolo-ios-app)
and a bundled Core ML model under AGPL-3.0. Retain the vendor license and local
patches. Apple supplies map display, place search and walking directions;
OpenStreetMap / FOSSGIS supplies bicycle routing; NCDOT and NYC Open Data supply
historical crash records. See provider files for source URLs and clustering criteria.
