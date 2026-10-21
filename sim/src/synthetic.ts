/**
 * SYNTHETIC day profiles: a crude clear-sky solar model and a made-up temperature curve.
 * ONLY for testing the pipeline and for demos when PVGIS data has not been downloaded.
 * Results produced from this are NOT thesis results. Every output file says so.
 */
import type { DayProfile } from "./pvgis";

const CUMULATIVE_DAYS = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];

export function syntheticDay(lat: number, lon: number, month: number): DayProfile {
  if (!Number.isInteger(month) || month < 1 || month > 12) throw new Error("month must be 1..12");
  const doy = CUMULATIVE_DAYS[month - 1]! + 15;
  const rad = Math.PI / 180;
  const decl = 23.44 * rad * Math.sin((2 * Math.PI * (284 + doy)) / 365);
  const meanTemp = 21 + 9 * Math.sin((2 * Math.PI * (doy - 105)) / 365) + (30 - lat) * 0.4;
  const whPerKwp: number[] = [];
  const t2m: number[] = [];
  for (let h = 0; h < 24; h++) {
    // Clock time is UTC+2 (meridian 30 E); solar time shifts 4 minutes per degree of longitude.
    const solarTime = h + 0.5 + (lon - 30) / 15;
    const hourAngle = 15 * rad * (solarTime - 12);
    const sinElev = Math.sin(lat * rad) * Math.sin(decl) + Math.cos(lat * rad) * Math.cos(decl) * Math.cos(hourAngle);
    whPerKwp.push(sinElev > 0 ? Math.round(800 * Math.pow(sinElev, 1.2)) : 0);
    t2m.push(Math.round((meanTemp + 7 * Math.cos((2 * Math.PI * (h - 15)) / 24)) * 10) / 10);
  }
  return { date: `2020-${String(month).padStart(2, "0")}-15`, utcOffsetHours: 2, whPerKwp, t2m };
}
