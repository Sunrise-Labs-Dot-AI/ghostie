const navItems = Array.from(document.querySelectorAll("[data-panel]"));
const panels = Array.from(document.querySelectorAll(".panel"));

function selectPanel(id) {
  navItems.forEach((item) => {
    item.classList.toggle("is-active", item.dataset.panel === id);
  });
  panels.forEach((panel) => {
    panel.classList.toggle("is-active", panel.id === id);
  });
}

navItems.forEach((item) => {
  item.addEventListener("click", () => selectPanel(item.dataset.panel));
});

if (window.lucide) {
  window.lucide.createIcons({
    strokeWidth: 2
  });
}
