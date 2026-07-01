// ────────────────────────────────────────────────────────────
// Treatment — the ONE canonical Wrapped look.
// "Sunrise": warm editorial gradients, Instrument Serif display numbers,
// soft film grain. The strongest of the original three systems (receipt and
// pager were deleted — less choice, more polish).
// Declares: name, fonts, ink, background palette per card key.
// ────────────────────────────────────────────────────────────

const TREATMENTS = {
  sunrise: {
    id: 'sunrise',
    name: 'Sunrise',
    serif: '"Instrument Serif", "Cormorant Garamond", Georgia, serif',
    sans: '"Inter", -apple-system, system-ui, sans-serif',
    mono: '"JetBrains Mono", ui-monospace, monospace',
    titleFont: 'serif',           // which family the big headlines use
    numberFont: 'serif',
    bodyFont: 'sans',
    italicNumbers: true,
    grain: 0.06,
    cards: [
      // 1 cover — soft peach to coral
      { bg: 'linear-gradient(160deg, #ffd9b3 0%, #ff8b6b 45%, #d94a6f 100%)', ink: '#1a0d1a', soft: '#1a0d1a' },
      // 2 hero number — molten orange
      { bg: 'linear-gradient(180deg, #ffb37a 0%, #ff5e3a 60%, #b21d4d 100%)', ink: '#1a0a14', soft: '#3a1020' },
      // 3 top people — magenta dusk
      { bg: 'linear-gradient(170deg, #ffa1c4 0%, #c84d96 55%, #5a1b6f 100%)', ink: '#fff4ee', soft: 'rgba(255,244,238,0.85)' },
      // 4 reply behavior — violet twilight
      { bg: 'linear-gradient(190deg, #ffb29c 0%, #b95aa3 50%, #2e1859 100%)', ink: '#fff', soft: 'rgba(255,255,255,0.78)' },
      // 5 ball in court — plum
      { bg: 'linear-gradient(195deg, #d98fbf 0%, #8a3f86 50%, #241455 100%)', ink: '#fff', soft: 'rgba(255,255,255,0.78)' },
      // 6 group chat — indigo night
      { bg: 'linear-gradient(200deg, #ff7a8a 0%, #6a3a9a 50%, #0e0a3a 100%)', ink: '#fff', soft: 'rgba(255,255,255,0.74)' },
      // 7 archetype — ink with peach flare
      { bg: 'radial-gradient(120% 90% at 80% 10%, #ff7a4a 0%, #c41f55 35%, #2a0a2a 75%, #0a0612 100%)', ink: '#fff1e6', soft: 'rgba(255,241,230,0.78)' },
      // 8 share — cream
      { bg: 'linear-gradient(180deg, #fff3e0 0%, #ffd6c2 100%)', ink: '#231016', soft: '#5a2a3a' },
    ],
  },
};

window.TREATMENTS = TREATMENTS;
