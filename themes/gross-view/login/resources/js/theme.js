/**
 * Applies the theme and UI language persisted by the gross-view app to the
 * Keycloak login page, and mirrors Keycloak's rendered language back into the
 * app's storage.
 *
 * The app and Keycloak are served from the same origin (nginx routes both `/`
 * and `/sso/` on `https://gross-view.local`), so the login page can read the
 * shared `localStorage` keys `gross-view:theme` and `gross-view:locale` and
 * mirror the site's color scheme (via the `data-theme` attribute) and
 * language (via the `lang` attribute) on `<html>`.
 *
 * The script is loaded from `<head>` (via `scripts=` in `theme.properties`),
 * so it runs before the first paint and prevents a light-to-dark flash.
 *
 * Storage keys must stay in sync with `THEME_STORAGE_KEY` in
 * `src/features/theme/model.ts` and `LOCALE_STORAGE_KEY` in
 * `src/features/locale/model.ts` of the gross-view-ui repository.
 */
(function () {
  var THEME_STORAGE_KEY = 'gross-view:theme';
  var LOCALE_STORAGE_KEY = 'gross-view:locale';
  var LOCALE_COOKIE_NAME = 'KEYCLOAK_LOCALE';

  function isLocale(value) {
    return value === 'ru' || value === 'en';
  }

  function applyTheme() {
    var theme = 'light';
    try {
      theme = window.localStorage.getItem(THEME_STORAGE_KEY) === 'dark' ? 'dark' : 'light';
    } catch (e) {
      // Ignore storage errors: fall back to the light theme.
    }
    document.documentElement.dataset.theme = theme;
  }

  /**
   * Mirrors the language Keycloak rendered this page in (already applied to
   * the `lang` attribute by the login template) back into the app's
   * `localStorage` and cookie, so the SPA stays in the same language.
   */
  function mirrorLocale() {
    var locale = document.documentElement.lang;
    if (!isLocale(locale)) {
      return;
    }
    try {
      window.localStorage.setItem(LOCALE_STORAGE_KEY, locale);
    } catch (e) {
      // Ignore storage errors: the app picks the cookie up instead.
    }
    try {
      document.cookie =
        LOCALE_COOKIE_NAME + '=' + locale + '; path=/; max-age=31536000; SameSite=Lax';
    } catch (e) {
      // Ignore cookie errors.
    }
  }

  applyTheme();
  mirrorLocale();

  // Re-apply when the theme changes in another tab of the app.
  window.addEventListener('storage', function (event) {
    if (event.key === THEME_STORAGE_KEY) {
      applyTheme();
    }
  });
})();
