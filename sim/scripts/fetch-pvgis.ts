/**
 * Downloads one year of hourly PVGIS data for each location and saves it in <repo>/data/pvgis/.
 * Run from the sim/ folder:  npm run fetch-pvgis
 * Needs internet access. After it runs, the app works offline from the saved files.
 */
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { LOCATIONS, PVGIS_SETTINGS } from "../src/locations";
import { parsePvgis } from "../src/pvgis";

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(here, "../../data/pvgis");
const VERSIONS = ["v5_3", "v5_2"]; // try the newer API first

async function fetchOne(lat: number, lon: number): Promise<{ text: string; version: string }> {
  const s = PVGIS_SETTINGS;
  const query =
    `lat=${lat}&lon=${lon}&peakpower=${s.peakPowerKw}&loss=${s.lossPercent}` +
    `&angle=${s.tiltDeg}&aspect=${s.aspectDeg}&startyear=${s.year}&endyear=${s.year}` +
    `&pvcalculation=1&outputformat=json`;
  let lastError = "";
  for (const version of VERSIONS) {
    const url = `https://re.jrc.ec.europa.eu/api/${version}/seriescalc?${query}`;
    const res = await fetch(url);
    const text = await res.text();
    if (res.ok) return { text, version };
    lastError = `${version}: HTTP ${res.status} ${text.slice(0, 200)}`;
  }
  throw new Error(lastError);
}

await mkdir(outDir, { recursive: true });
for (const loc of LOCATIONS) {
  process.stdout.write(`${loc.name} ... `);
  const { text, version } = await fetchOne(loc.lat, loc.lon);
  const series = parsePvgis(JSON.parse(text), { peakPowerKw: PVGIS_SETTINGS.peakPowerKw });
  let annualWh = 0;
  let tSum = 0;
  let tMax = -Infinity;
  for (const p of series.points.values()) {
    annualWh += p.whPerKwp;
    tSum += p.t2m;
    tMax = Math.max(tMax, p.t2m);
  }
  const file = path.join(outDir, `${loc.key}_${series.year}.json`);
  await writeFile(file, text);
  console.log(
    `ok (${version}) rows=${series.points.size} year=${series.year} ` +
      `yield=${(annualWh / 1000).toFixed(0)} kWh/kWp mean T=${(tSum / series.points.size).toFixed(1)}C max T=${tMax.toFixed(1)}C`,
  );
}
console.log(`Saved to ${outDir}`);
