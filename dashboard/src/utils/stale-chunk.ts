/**
 * Browsers word a failed lazy-route import differently (Chromium, Firefox, Safari, Vite's preload helper).
 * After a redeploy the old hashed chunk is gone (404), so a tab opened before it fails this way.
 */
const STALE_CHUNK_PATTERNS = [
  /Failed to fetch dynamically imported module/i,
  /error loading dynamically imported module/i,
  /Importing a module script failed/i,
  /Unable to preload CSS/i,
];

export function isStaleChunkError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return STALE_CHUNK_PATTERNS.some((pattern) => pattern.test(message));
}
