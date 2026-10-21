import { describe, expect, it } from "vitest";
import { buildPvgisUrl, locationCacheKey, roundCoordinates, validateCoordinates } from "../src/location";

describe("user-entered location", () => {
  it("accepts points inside Egypt", () => {
    expect(validateCoordinates(30.04, 31.24)).toEqual({ lat: 30.04, lon: 31.24 }); // Cairo
    expect(validateCoordinates(25.45, 30.55)).toEqual({ lat: 25.45, lon: 30.55 }); // El Kharga
  });

  it("rejects points outside Egypt and non-numbers", () => {
    expect(() => validateCoordinates(48.85, 2.35)).toThrow(/outside Egypt/); // Paris
    expect(() => validateCoordinates(0, 0)).toThrow(/outside Egypt/);
    expect(() => validateCoordinates("30", 31)).toThrow(/numbers/);
    expect(() => validateCoordinates(NaN, 31)).toThrow(/numbers/);
    expect(() => validateCoordinates(30, undefined)).toThrow(/numbers/);
  });

  it("nearby points share a cache key and distant ones do not", () => {
    expect(locationCacheKey({ lat: 30.041, lon: 31.238 })).toBe(locationCacheKey({ lat: 30.044, lon: 31.242 }));
    expect(locationCacheKey({ lat: 30.04, lon: 31.24 })).toBe("30.04_31.24");
    expect(locationCacheKey({ lat: 25.45, lon: 30.55 })).not.toBe(locationCacheKey({ lat: 30.04, lon: 31.24 }));
    expect(roundCoordinates({ lat: 25.456, lon: 30.554 })).toEqual({ lat: 25.46, lon: 30.55 });
  });

  it("builds the PVGIS request from the rounded coordinates and the fixed system assumptions", () => {
    const url = buildPvgisUrl("v5_3", { lat: 25.4567, lon: 30.5512 });
    expect(url).toContain("/api/v5_3/seriescalc?");
    expect(url).toContain("lat=25.46&lon=30.55");
    expect(url).toContain("peakpower=1");
    expect(url).toContain("angle=25&aspect=0");
    expect(url).toContain("startyear=2020&endyear=2020");
    expect(url).toContain("outputformat=json");
  });
});
