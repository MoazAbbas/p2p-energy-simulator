/**
 * User-entered locations. The user types latitude and longitude; we only accept points inside
 * Egypt's bounding box (a rectangle around the country, so a few border points outside Egypt pass).
 * Results are cached per coordinates rounded to 2 decimals (about 1 km).
 */
import { PVGIS_SETTINGS } from "./locations";

export const EGYPT_BOUNDS = { latMin: 21.9, latMax: 31.7, lonMin: 24.6, lonMax: 37.0 } as const;

export interface Coordinates {
  lat: number;
  lon: number;
}

export function validateCoordinates(lat: unknown, lon: unknown): Coordinates {
  if (typeof lat !== "number" || typeof lon !== "number" || !Number.isFinite(lat) || !Number.isFinite(lon)) {
    throw new Error("latitude and longitude must be numbers");
  }
  const b = EGYPT_BOUNDS;
  if (lat < b.latMin || lat > b.latMax || lon < b.lonMin || lon > b.lonMax) {
    throw new Error(
      `location is outside Egypt (latitude ${b.latMin} to ${b.latMax}, longitude ${b.lonMin} to ${b.lonMax})`,
    );
  }
  return { lat, lon };
}

export function roundCoordinates(c: Coordinates): Coordinates {
  return { lat: Math.round(c.lat * 100) / 100, lon: Math.round(c.lon * 100) / 100 };
}

/** Stable cache key, e.g. "30.04_31.24". Nearby points (about 1 km) share a key. */
export function locationCacheKey(c: Coordinates): string {
  const r = roundCoordinates(c);
  return `${r.lat.toFixed(2)}_${r.lon.toFixed(2)}`;
}

export function buildPvgisUrl(version: string, c: Coordinates, s: typeof PVGIS_SETTINGS = PVGIS_SETTINGS): string {
  const r = roundCoordinates(c);
  return (
    `https://re.jrc.ec.europa.eu/api/${version}/seriescalc?lat=${r.lat}&lon=${r.lon}` +
    `&peakpower=${s.peakPowerKw}&loss=${s.lossPercent}&angle=${s.tiltDeg}&aspect=${s.aspectDeg}` +
    `&startyear=${s.year}&endyear=${s.year}&pvcalculation=1&outputformat=json`
  );
}
