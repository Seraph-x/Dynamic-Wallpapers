"use strict";

// Keep the reader in the same section across translations; no app preferences or storage are changed.
function updateLanguageLinks() {
  for (const link of document.querySelectorAll("a[data-help-language]")) {
    link.hash = window.location.hash;
  }
}
window.addEventListener("hashchange", updateLanguageLinks);
updateLanguageLinks();

// WebKit can discard navigation to a missing local file before reporting a delegate error.
// In the app, ask the native window to validate and load the selected bundled language.
// In a normal browser these remain ordinary offline links.
for (const link of document.querySelectorAll("a[data-help-language]")) {
  link.addEventListener("click", event => {
    const navigation = window.webkit?.messageHandlers?.helpLanguage;
    if (navigation) {
      event.preventDefault();
      navigation.postMessage(link.dataset.helpLanguage);
    }
  });
}
