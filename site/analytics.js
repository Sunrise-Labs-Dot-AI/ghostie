// Privacy-first web analytics for the Ghostie / messagesfor.ai marketing site.
//
// Same PostHog project as the macOS app, so site download-intent and in-app
// usage live in one project. Deliberately minimal and cookieless:
//   • persistence: 'memory'      → no cookies, no localStorage (no consent banner needed)
//   • person_profiles: 'never'   → anonymous events only, no per-person profiles
//   • autocapture: false         → no broad DOM/PII capture
//   • disable_session_recording  → no session replay / screen capture
//   • advanced_disable_decide    → no feature-flag/decide round-trips; pure ingestion
//
// It captures exactly two things: page views and clicks on the Download CTA.
// No message data, no contact data, no PII. Mirrors the app's stance and is
// disclosed in privacy.html ("Website analytics").
//
// The PostHog project API key below is a *publishable* client key (ingestion
// only) — it is designed to live in client-side code, like every PostHog web
// install. It is not a secret.
(function () {
  var POSTHOG_KEY = "phc_minUK2QUKQTDEKCExNk77kV28BdKFj3AuaspnYUNH3qX";
  var POSTHOG_HOST = "https://us.i.posthog.com";

  // Official PostHog web snippet (loads array.js, then init runs below).
  !function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);

  posthog.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    persistence: "memory",
    person_profiles: "never",
    autocapture: false,
    capture_pageview: true,
    capture_pageleave: false,
    disable_session_recording: true,
    disable_surveys: true,
    advanced_disable_decide: true,
  });

  // Delegated capture for the Download CTA. One listener covers every current
  // and future link to the download endpoint (no per-button edits). Properties
  // are coarse and PII-free: which button, its visible label, and the page.
  document.addEventListener(
    "click",
    function (ev) {
      var el = ev.target;
      var a = el && el.closest
        ? el.closest('a[href*="/api/download"], a[href*="/releases/latest/download/"]')
        : null;
      if (!a || !window.posthog) return;
      posthog.capture("download_click", {
        cta_id: a.id || null,
        cta_text: (a.textContent || "").replace(/\s+/g, " ").trim().slice(0, 40),
        page: location.pathname,
      });
    },
    true
  );
})();
