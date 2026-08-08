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
      var toggle = document.querySelector('.kc-btn--icon');
      if (toggle) {
        renderThemeToggle(toggle, document.documentElement.dataset.theme === 'dark');
      }
    }
  });

  // ---------------------------------------------------------------------------
  // Header toolbar
  //
  // Rebuilds the Keycloak header so it mirrors the site's sticky toolbar:
  // a brand block ("GV" + "Gross View") on the left and, on the right, the
  // theme toggle and the RU / EN segmented locale switcher. All of these
  // already exist in the site's header, so the login page no longer looks
  // foreign. The brand links to the site root, which nginx routes to the SPA.
  // ---------------------------------------------------------------------------

  var MOON_ICON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>';
  var SUN_ICON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>';

  function isRussian() {
    return (document.documentElement.lang || '').substring(0, 2).toLowerCase() === 'ru';
  }

  function currentLocaleCode() {
    return (document.documentElement.lang || '').substring(0, 2).toLowerCase();
  }

  /** Extracts the two-letter locale code from a Keycloak locale switch link. */
  function localeCodeFromLink(link) {
    try {
      var params = new URL(link.href).searchParams;
      var code = params.get('ui_locales') || params.get('kc_locale');
      if (code) {
        return code.substring(0, 2).toLowerCase();
      }
    } catch (e) {
      // Fall through to the heuristics below.
    }
    var lang = link.getAttribute('lang');
    if (lang) {
      return lang.substring(0, 2).toLowerCase();
    }
    var label = (link.textContent || '').toLowerCase();
    if (/ru|russ|рус/.test(label)) {
      return 'ru';
    }
    if (/en|engl|англ/.test(label)) {
      return 'en';
    }
    return '';
  }

  function renderThemeToggle(button, isDark) {
    button.innerHTML = isDark ? SUN_ICON : MOON_ICON;
    button.setAttribute(
      'aria-label',
      isDark
        ? isRussian() ? 'Переключить на светлую тему' : 'Switch to light theme'
        : isRussian() ? 'Переключить на тёмную тему' : 'Switch to dark theme'
    );
    button.title = isDark
      ? isRussian() ? 'Светлая тема' : 'Light theme'
      : isRussian() ? 'Тёмная тема' : 'Dark theme';
  }

  function buildThemeToggle() {
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'kc-btn kc-btn--icon';
    renderThemeToggle(button, document.documentElement.dataset.theme === 'dark');
    button.addEventListener('click', function () {
      var next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      document.documentElement.dataset.theme = next;
      try {
        window.localStorage.setItem(THEME_STORAGE_KEY, next);
      } catch (e) {
        // Non-fatal: the theme still applies for the current page.
      }
      renderThemeToggle(button, next === 'dark');
    });
    return button;
  }

  /**
   * Rebuilds Keycloak's locale dropdown into the site's RU / EN segmented
   * control, reusing the original switch links so the locale choice persists.
   */
  function buildLocaleSwitcher(localeEl) {
    var switcher = document.createElement('div');
    switcher.className = 'kc-locale-switcher';
    switcher.setAttribute('role', 'group');
    switcher.setAttribute('aria-label', isRussian() ? 'Язык' : 'Language');

    var current = currentLocaleCode();
    var links = localeEl.querySelectorAll('a[href]');
    links.forEach(function (link) {
      if (link.id === 'kc-current-locale-link') {
        return;
      }
      var code = localeCodeFromLink(link);
      if (!code) {
        return;
      }
      var isActive = code === current;
      var option = document.createElement('button');
      option.type = 'button';
      option.textContent = code.toUpperCase();
      option.setAttribute('aria-pressed', isActive ? 'true' : 'false');
      if (isActive) {
        option.className = 'is-active';
      }
      option.addEventListener('click', function () {
        window.location.href = link.href;
      });
      switcher.appendChild(option);
    });
    return switcher;
  }

  function buildHeaderToolbar() {
    var header = document.getElementById('kc-header');
    if (!header) {
      return;
    }

    var inner = document.createElement('div');
    inner.className = 'kc-header__inner';
    header.appendChild(inner);

    var wrapper = document.getElementById('kc-header-wrapper');
    if (wrapper) {
      wrapper.textContent = '';
      var brand = document.createElement('a');
      brand.className = 'kc-brand';
      brand.href = '/';
      brand.setAttribute('aria-label', 'Gross View');
      var logo = document.createElement('div');
      logo.className = 'kc-brand__logo';
      logo.textContent = 'GV';
      var title = document.createElement('span');
      title.className = 'kc-brand__title';
      title.textContent = 'Gross View';
      brand.appendChild(logo);
      brand.appendChild(title);
      wrapper.appendChild(brand);
      inner.appendChild(wrapper);
    }

    var nav = document.createElement('nav');
    nav.className = 'kc-header__nav';
    nav.setAttribute('aria-label', isRussian() ? 'Основная навигация' : 'Main navigation');

    var locale = document.getElementById('kc-locale');
    if (locale) {
      var switcher = buildLocaleSwitcher(locale);
      if (switcher.childNodes.length > 0) {
        nav.appendChild(switcher);
      }
      locale.parentNode.removeChild(locale);
    }

    nav.appendChild(buildThemeToggle());

    inner.appendChild(nav);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', buildHeaderToolbar);
  } else {
    buildHeaderToolbar();
  }
})();
