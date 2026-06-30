// "Try the new version in Flow" first-visit-of-the-day popup.
//
// Shows the #flow-announce modal once per calendar day, per browser. The
// last-shown date is stored in localStorage; if it isn't today, the popup is
// revealed on load. "Maybe later" advances to a second stage asking the user
// to drop @ian a note; dismissing it (Got it / close / backdrop / Esc) or
// following "Try it now" records today as seen so it won't reappear until
// tomorrow. Purely front-end: no controller, model or migration changes.

(function () {
  var KEY = "flow_announce_seen";

  function today() {
    return new Date().toISOString().slice(0, 10); // e.g. 2026-06-22
  }

  function markSeen() {
    try {
      localStorage.setItem(KEY, today());
    } catch (e) {
      // localStorage may be unavailable (private mode); fail quietly.
    }
  }

  function seenToday() {
    try {
      return localStorage.getItem(KEY) === today();
    } catch (e) {
      return false;
    }
  }

  function hide(modal) {
    modal.classList.add("hidden");
  }

  // Reveal a named stage ([data-flow-stage="..."]) and hide the others.
  function showStage(modal, name) {
    var stages = modal.querySelectorAll("[data-flow-stage]");
    Array.prototype.forEach.call(stages, function (stage) {
      if (stage.getAttribute("data-flow-stage") === name) {
        stage.classList.remove("hidden");
      } else {
        stage.classList.add("hidden");
      }
    });
  }

  function init() {
    var modal = document.getElementById("flow-announce");
    if (!modal) {
      return; // partial not rendered (e.g. non-38degrees theme)
    }

    if (!seenToday()) {
      modal.classList.remove("hidden");
    }

    // "Try it now" — record as seen, then redirect.
    var now = modal.querySelector("#flow-now");
    if (now) {
      now.addEventListener("click", function () {
        markSeen();
        var url = modal.getAttribute("data-flow-url");
        if (url) {
          window.location.href = url;
        }
      });
    }

    // "Maybe later" — don't dismiss yet; show the "drop @ian a note" stage.
    var later = modal.querySelector(".flow-later");
    if (later) {
      later.addEventListener("click", function () {
        showStage(modal, "later");
      });
    }

    // Close button and "Got it" — record as seen and dismiss.
    var dismissers = modal.querySelectorAll(".flow-close, .flow-done");
    Array.prototype.forEach.call(dismissers, function (el) {
      el.addEventListener("click", function () {
        markSeen();
        hide(modal);
      });
    });

    // Clicking the dark backdrop (but not the modal itself) dismisses.
    modal.addEventListener("click", function (event) {
      if (event.target === modal) {
        markSeen();
        hide(modal);
      }
    });

    // Esc dismisses while the modal is visible. Bound once on document so it
    // doesn't accumulate across Turbolinks navigations; it re-finds the modal
    // each time it fires.
    if (!document.flowAnnounceEscBound) {
      document.flowAnnounceEscBound = true;
      document.addEventListener("keydown", function (event) {
        if (event.key !== "Escape") {
          return;
        }
        var current = document.getElementById("flow-announce");
        if (current && !current.classList.contains("hidden")) {
          markSeen();
          hide(current);
        }
      });
    }
  }

  // Run on Turbolinks navigations and on a plain initial load.
  document.addEventListener("turbolinks:load", init);
  if (!window.Turbolinks) {
    document.addEventListener("DOMContentLoaded", init);
  }
})();
