/** Locations offered in the app. Coordinates are approximate city centres. */
export interface Location {
  key: string;
  name: string;
  lat: number;
  lon: number;
}

export const LOCATIONS: readonly Location[] = [
  { key: "alexandria", name: "Alexandria", lat: 31.2, lon: 29.92 },
  { key: "cairo", name: "Cairo", lat: 30.04, lon: 31.24 },
  // New Valley governorate (Wadi El Gedeed), represented by its capital El Kharga.
  { key: "new-valley", name: "New Valley (Wadi El Gedeed)", lat: 25.45, lon: 30.55 },
];

/** PVGIS system assumptions used for every request (documented in the thesis). */
export const PVGIS_SETTINGS = {
  year: 2020,
  peakPowerKw: 1,
  /** system losses in percent */
  lossPercent: 14,
  /** panel tilt from horizontal, degrees (fixed simplification) */
  tiltDeg: 25,
  /** 0 = facing south */
  aspectDeg: 0,
} as const;
