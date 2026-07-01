const navItems = Array.from(document.querySelectorAll("[data-panel]"));
const panels = Array.from(document.querySelectorAll(".panel"));
const contextGhostie = document.querySelector("#contextGhostie");

const ghostieByPanel = {
  messages: {
    src: "../sprites/out/app/ghostie-macos-icon-classic-clean-v3.png",
    alt: "Ghostie for Messages"
  },
  drafts: {
    src: "../sprites/out/app/ghostie-feature-drafts-v2.png",
    alt: "Ghostie for Drafts"
  },
  scheduled: {
    src: "../sprites/out/app/ghostie-feature-approval-v2.png",
    alt: "Ghostie for Scheduled"
  },
  history: {
    src: "../sprites/out/app/ghostie-macos-icon-classic-utility-v3.png",
    alt: "Ghostie for History"
  },
  dontghost: {
    src: "../sprites/out/app/ghostie-feature-dont-ghost-v2.png",
    alt: "Ghostie for Don't Ghost"
  },
  eq: {
    src: "../sprites/out/app/ghostie-feature-tone-check-v2.png",
    alt: "Ghostie for EQ"
  },
  birthdays: {
    src: "../sprites/out/app/ghostie-feature-birthday-v2.png",
    alt: "Ghostie for Birthdays"
  },
  wrapped: {
    src: "../sprites/out/app/ghostie-feature-wrapped-v2.png",
    alt: "Ghostie for Wrapped"
  },
  severance: {
    src: "../sprites/out/app/ghostie-macos-icon-office-v1.png",
    alt: "Ghostie for Severance"
  },
  analytics: {
    src: "../sprites/out/app/ghostie-macos-icon-analytics-v1.png",
    alt: "Ghostie for Analytics"
  },
  voice: {
    src: "../sprites/out/app/ghostie-feature-texting-voice-v2.png",
    alt: "Ghostie for Style"
  },
  automations: {
    src: "../sprites/out/app/ghostie-feature-automations-v2.png",
    alt: "Ghostie for Automations"
  },
  settings: {
    src: "../sprites/out/app/ghostie-macos-icon-classic-utility-v3.png",
    alt: "Ghostie for Settings"
  }
};

Object.values(ghostieByPanel).forEach(({ src }) => {
  const image = new Image();
  image.src = src;
});

function updateContextGhostie(id) {
  if (!contextGhostie) return;
  const next = ghostieByPanel[id] || ghostieByPanel.messages;
  if (contextGhostie.getAttribute("src") === next.src) {
    contextGhostie.alt = next.alt;
    return;
  }

  contextGhostie.classList.add("is-swapping");
  window.setTimeout(() => {
    contextGhostie.src = next.src;
    contextGhostie.alt = next.alt;
    contextGhostie.addEventListener(
      "load",
      () => contextGhostie.classList.remove("is-swapping"),
      { once: true }
    );
  }, 90);
}

function selectPanel(id) {
  navItems.forEach((item) => {
    item.classList.toggle("active", item.dataset.panel === id);
  });
  panels.forEach((panel) => {
    panel.classList.toggle("active", panel.id === id);
  });
  updateContextGhostie(id);
}

navItems.forEach((item) => {
  item.addEventListener("click", () => selectPanel(item.dataset.panel));
});

if (window.lucide) {
  window.lucide.createIcons({ strokeWidth: 2 });
}
