// Collapsible sidebars on desktop: a button hides/shows the left navigation (from 50em wide) and the right "On this
// page" list (from 72em, where Starlight shows it). The choice is remembered per browser (localStorage, best effort).
// Runs in <head> so a hidden sidebar never flashes; the buttons are added once the page is parsed. Styles: custom.css.
(() => {
  const root = document.documentElement;
  const KEYS = { sidebar: 'anvil-hide-sidebar', toc: 'anvil-hide-toc' };
  const get = (k) => { try { return localStorage.getItem(k) === '1'; } catch { return false; } };
  const set = (k, v) => { try { v ? localStorage.setItem(k, '1') : localStorage.removeItem(k); } catch {} };
  if (get(KEYS.sidebar)) root.dataset.hideSidebar = '';
  if (get(KEYS.toc)) root.dataset.hideToc = '';
  const LABELS = {
    sidebar: ['Hide navigation', 'Show navigation'],
    toc: ['Hide “On this page”', 'Show “On this page”'],
  };
  const sync = (btn, which) => {
    const hidden = which === 'sidebar' ? 'hideSidebar' in root.dataset : 'hideToc' in root.dataset;
    const label = LABELS[which][hidden ? 1 : 0];
    btn.setAttribute('aria-label', label);
    btn.title = label;
    btn.setAttribute('aria-expanded', String(!hidden));
  };
  const make = (which) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `sl-toggle sl-toggle-${which}`;
    btn.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path d="M15 6l-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    btn.addEventListener('click', () => {
      const attr = which === 'sidebar' ? 'hideSidebar' : 'hideToc';
      const now = !(attr in root.dataset);
      now ? (root.dataset[attr] = '') : delete root.dataset[attr];
      set(KEYS[which], now);
      sync(btn, which);
    });
    sync(btn, which);
    document.body.append(btn);
  };
  const init = () => {
    if (root.hasAttribute('data-has-sidebar')) make('sidebar');
    if (root.hasAttribute('data-has-toc')) make('toc');
  };
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
})();
