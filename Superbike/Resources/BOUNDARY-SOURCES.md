# Map boundary sources

Downloaded October 17, 2026 from the U.S. Census Bureau TIGERweb services.
These unmodified ArcGIS JSON responses use WGS84 output, with a requested
maximum geometry simplification offset of 0.00001 degrees (approximately 1m).

`Cary-Boundary.json`: BAS 2026 Incorporated Places, GEOID 3710740 (Cary town).
Includes disconnected municipal areas and holes; Cary is not equated with NC-02.

https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/Places_CouSub_ConCity_SubMCD/MapServer/4/query

Query: `STATE='37' AND NAME='Cary town'`; fields `GEOID,NAME,STATE`; `outSR=4326`.

`NC02-119-Boundary.json`: January 1, 2026 vintage CURRENT 119th Congress layer,
GEOID 3702, CDSESSN 119, state 37, congressional district 02.

https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/Legislative/MapServer/4/query

Query: `STATE='37' AND CD119='02'`; fields `GEOID,NAME,CDSESSN,STATE,CD119`; `outSR=4326`.

Representative Deborah Ross's current district is NC-02, 119th Congress
(January 2025–January 2027). The prospective 120th Congress election map is a
different layer and must not silently replace this current-service boundary.

Representative source: https://ross.house.gov/our-district

These boundaries define display/filter areas, not additional crash records.
The historical bicycle incidents come separately from official NCDOT records.
