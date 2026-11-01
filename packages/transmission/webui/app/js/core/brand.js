/**
 * Krate wave mark as inline SVG (no image fetch).
 * Strokes use --kr-primary / muted foreground so Dark/Light stay coherent.
 */

import { svg } from './dom.js?v=2.0.0';

export const MARK_VIEWBOX = '0 0 32 32';
export const MARK_RATIO = 1;

/**
 * @param {{ size?: number, label?: string, className?: string }} [opts]
 * @returns {SVGElement}
 */
export function krateMark(opts = {}) {
  const width = Number.isFinite(opts.size) && opts.size > 0 ? opts.size : 24;
  const height = width;
  const a11y = opts.label ? { role: 'img', 'aria-label': opts.label } : { 'aria-hidden': 'true' };
  const stroke = 'var(--kr-primary)';
  const muted = 'var(--kr-fg-muted)';
  return svg('svg', {
    class: ['brand-mark', 'kr-mark', opts.className].filter(Boolean).join(' '),
    viewBox: MARK_VIEWBOX,
    width,
    height,
    focusable: 'false',
    ...a11y,
  }, [
    svg('path', {
      d: 'M4 18c3.5-6 7-6 10.5 0s7 6 10.5 0',
      fill: 'none',
      stroke,
      'stroke-width': '3.2',
      'stroke-linecap': 'round',
    }),
    svg('path', {
      d: 'M4 12c3.5-6 7-6 10.5 0s7 6 10.5 0',
      fill: 'none',
      stroke: muted,
      'stroke-width': '3.2',
      'stroke-linecap': 'round',
      opacity: '0.55',
    }),
    svg('circle', {
      cx: '26',
      cy: '10',
      r: '2.4',
      fill: stroke,
    }),
  ]);
}
