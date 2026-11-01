/**
 * Theme variants — Krate HarmonyUI Dark / Light / Auto.
 *
 * Order: local pick (`kr-transmission-variant`), and when that is `auto`
 * (or unset), the HarmonyUI `krate_theme` cookie, then prefers-color-scheme,
 * then dark.
 *
 * Writes `data-kr-variant` on <html>.
 */

export const VARIANTS = Object.freeze(['dark', 'light']);
export const STORAGE_KEY = 'kr-transmission-variant';
const COOKIE_KR = /(?:^|;\s*)krate_theme=([^;]*)/;

/**
 * @param {string} cookieString
 * @returns {string} dark|light
 */
export function cookieVariant(cookieString) {
  const raw = typeof cookieString === 'string' ? cookieString : '';
  let value = '';
  const mKr = raw.match(COOKIE_KR);
  if (mKr) {
    try { value = decodeURIComponent(mKr[1]); } catch { value = mKr[1]; }
  }
  value = String(value || '').toLowerCase();
  if (VARIANTS.includes(value)) return value;
  try {
    if (globalThis.matchMedia && globalThis.matchMedia('(prefers-color-scheme: light)').matches) {
      return 'light';
    }
  } catch { /* ignore */ }
  return 'dark';
}

/**
 * @param {string|null} stored
 * @param {string} cookieString
 * @returns {string}
 */
export function resolveVariant(stored, cookieString) {
  return VARIANTS.includes(stored) ? stored : cookieVariant(cookieString);
}

/** @returns {'auto'|string} */
export function preference() {
  try {
    const v = globalThis.localStorage.getItem(STORAGE_KEY);
    return VARIANTS.includes(v) ? v : 'auto';
  } catch {
    return 'auto';
  }
}

const listeners = new Set();
let started = false;

/** @returns {string} */
export function currentVariant() {
  return document.documentElement.getAttribute('data-kr-variant') || 'dark';
}

function apply(variant) {
  if (variant === currentVariant() && started) return;
  document.documentElement.setAttribute('data-kr-variant', variant);
  document.documentElement.classList.toggle('dark', variant === 'dark');
  document.documentElement.setAttribute('data-theme', variant);
  for (const fn of [...listeners]) {
    try {
      fn(variant);
    } catch (err) {
      console.error(err);
    }
  }
}

function follow() {
  if (preference() !== 'auto') return;
  apply(cookieVariant(document.cookie));
}

/** Apply the resolved variant and start following the dashboard. Idempotent. */
export function startTheme() {
  const pick = preference();
  apply(resolveVariant(pick === 'auto' ? null : pick, document.cookie));
  if (started) return;
  started = true;
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) follow();
  });
  globalThis.addEventListener('focus', follow);
}

/**
 * Save a pick and apply it. `auto` clears the pick and follows the dashboard.
 * @param {'auto'|string} choice
 */
export function setVariant(choice) {
  try {
    if (VARIANTS.includes(choice)) globalThis.localStorage.setItem(STORAGE_KEY, choice);
    else globalThis.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // Storage blocked: the pick lasts for this page only.
  }
  apply(VARIANTS.includes(choice) ? choice : cookieVariant(document.cookie));
}

/**
 * @param {(variant: string) => void} fn
 * @returns {() => void}
 */
export function onVariant(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
