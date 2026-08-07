/**
 * Applies the theme persisted by the gross-view app to the Keycloak login page.
 *
 * The app and Keycloak are served from the same origin (nginx routes both `/`
 * and `/sso/` on `https://gross-view.local`), so the login page can read the
 * shared `localStorage` key `gross-view:theme` and mirror the site's color
 * scheme via the `data-theme` attribute on `<html>` (see `css/login.css`).
 *
 * The script is loaded from `<head>` (via `scripts=` in `theme.properties`),
 * so it runs before the first paint and prevents a light-to-dark flash.
 *
 * Storage key must stay in sync with `THEME_STORAGE_KEY` in
 * `src/features/theme/model.ts` of the gross-view-ui repository.
 */
(function () {
  var THEME_STORAGE_KEY = 'gross-view:theme';

  function applyTheme() {
    var theme = 'light';
    try {
      theme = window.localStorage.getItem(THEME_STORAGE_KEY) === 'dark' ? 'dark' : 'light';
    } catch (e) {
      // Ignore storage errors: fall back to the light theme.
    }
    document.documentElement.dataset.theme = theme;
  }

  applyTheme();

  // Re-apply when the theme changes in another tab of the app.
  window.addEventListener('storage', applyTheme);
})();
