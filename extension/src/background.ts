// MV3 service worker. Phase 3 (3.1) adds per-site permission requests,
// URL/caption/C2PA extraction and the native-messaging handshake.
//
// Host access is never granted at install: each allowlisted site is requested
// at runtime with chrome.permissions.request({ origins: [...] }), so the
// extension never holds <all_urls>.

chrome.runtime.onInstalled.addListener(() => {
  console.info("AI Exposure companion installed");
});
