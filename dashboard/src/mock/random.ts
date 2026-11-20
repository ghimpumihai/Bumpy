/** Small deterministic PRNG (mulberry32) so the mock dataset is identical on every load. */
export function createRandom(seed: number) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const gaussian = () => {
    const u = Math.max(next(), Number.EPSILON);
    const v = next();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  };
  return {
    next,
    gaussian,
    range: (min: number, max: number) => min + (max - min) * next(),
    chance: (probability: number) => next() < probability,
  };
}

export type Random = ReturnType<typeof createRandom>;

/** Stable 32-bit hash of a string (FNV-1a), used to derive per-cell and per-session seeds. */
export function hashString(value: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

/** Deterministic value in [0, 1) for a key. */
export function unitHash(key: string): number {
  return hashString(key) / 4294967296;
}
