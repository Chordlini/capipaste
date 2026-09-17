const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const INK = '#17171A';
const BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];

/* ---------- dither helpers ---------- */
// Draw with `paint(ctx, w, h)` in greyscale at low res, then Bayer-threshold into ink squares.
// `threshold`: a number cuts hard at that grey level (clean bitmap) instead of Bayer dithering.
function ditherInto(canvas, paint, { cell = 1, color = INK, threshold = null } = {}) {
  const w = Math.floor(canvas.width / cell), h = Math.floor(canvas.height / cell);
  const off = document.createElement('canvas');
  off.width = w; off.height = h;
  const o = off.getContext('2d');
  o.fillStyle = '#fff'; o.fillRect(0, 0, w, h);
  paint(o, w, h);
  const px = o.getImageData(0, 0, w, h).data;
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.fillStyle = color;
  // whole-pixel dots with a 1-pixel-or-so gap, so edges never blur
  const dot = cell <= 1 ? 1 : cell - Math.max(1, Math.round(cell * 0.14));
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const v = px[(y * w + x) * 4] / 255;
    const cut = threshold ?? (BAYER[y % 4][x % 4] + 0.5) / 16;
    if (v < cut) ctx.fillRect(x * cell, y * cell, dot, dot);
  }
}

/* ---------- nav: hairline once scrolled ---------- */
const nav = document.getElementById('nav');
const onScrollNav = () => nav.classList.toggle('scrolled', scrollY > 8);
addEventListener('scroll', onScrollNav, { passive: true });
onScrollNav();

/* ---------- logo: acorn dots snapped to device pixels ---------- */
// A scaled-down dither image aliases differently at every browser zoom, so the logo is drawn
// from a dot map with a whole number of device pixels per dot, and redrawn when zoom changes.
const ACORN_DOTS = ["000000000000000000000010000000", "000000000000000000010111010000", "000000000000000010101000100000", "000000000000000111010101110000", "000000000000001010101010100000", "000000000000001111111111000000", "000000000000001110001010000000", "000000010101011111010100000000", "000000100010101010001010000000", "000001110101010101011101010000", "000010001000101010101011101000", "000111011101110101110111011100", "001000100010001010101010111010", "001101110111011111011101111101", "001010101010101010101010101010", "110111011101111101110111111110", "001010101010101000101010001000", "010101110111010111011101111100", "111010101010101110001010111010", "011111111101110111111111111110", "001000001010101010101010000010", "011001000000000001000100010100", "001000000000000000000000000110", "011100010000000100010001010100", "001000000000000000000000001100", "001100000110000000011100011100", "001100001010000000101000001100", "000100010111000100011101011100", "000100000010000000001000001000", "000110000000010001000100011000", "000010000000001010000000111000", "000011000001000100010101110000", "000001100000000000000000100000", "000001100100010001000101100000", "000000110000000000000011000000", "000000011101010101010111000000", "000000001110000000001100000000", "000000000111111101110000000000", "000000000000111110100000000000"];
function drawLogos() {
  const dpr = devicePixelRatio || 1;
  document.querySelectorAll('canvas.logo').forEach(c => {
    const rows = ACORN_DOTS.length, cols = ACORN_DOTS[0].length;
    const cell = parseFloat(c.dataset.size || 34) * dpr / rows; // device px per dot (may be fractional)
    c.width = Math.round(cols * cell); c.height = Math.round(rows * cell);
    c.style.width = `${c.width / dpr}px`; c.style.height = `${c.height / dpr}px`;
    const ctx = c.getContext('2d');
    ctx.fillStyle = INK;
    // snap every dot's edges to whole device pixels: no blur, no seams, same size at any zoom
    const edge = (i) => Math.round(i * cell);
    ACORN_DOTS.forEach((row, y) => [...row].forEach((v, x) => {
      if (v === '1') ctx.fillRect(edge(x), edge(y), edge(x + 1) - edge(x), edge(y + 1) - edge(y));
    }));
  });
}
let dprQuery;
function watchZoom() {
  dprQuery?.removeEventListener('change', onZoom);
  dprQuery = matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
  dprQuery.addEventListener('change', onZoom);
}
function onZoom() { drawLogos(); drawWordmark?.(); drawTitles?.(); watchZoom(); }
drawLogos();
watchZoom();

/* ---------- headings print in through a dither mask ---------- */
// Pre-render 17 Bayer mask tiles (0..16 dots visible) as data URLs.
const masks = Array.from({ length: 17 }, (_, level) => {
  const c = document.createElement('canvas'); c.width = c.height = 8;
  const o = c.getContext('2d'); o.fillStyle = '#000';
  for (let y = 0; y < 4; y++) for (let x = 0; x < 4; x++) if (BAYER[y][x] < level) o.fillRect(x * 2, y * 2, 2, 2);
  return `url(${c.toDataURL()})`;
});
const printIO = new IntersectionObserver(entries => {
  for (const { target, isIntersecting } of entries) {
    if (!isIntersecting) continue;
    printIO.unobserve(target);
    let level = 0;
    const tick = () => {
      level++;
      if (level >= 16) { target.classList.add('printed'); return; }
      target.style.setProperty('--mask', masks[level]);
      setTimeout(tick, 45);
    };
    tick();
  }
}, { threshold: 0.4 });
document.querySelectorAll('.print').forEach(el => {
  if (reduced) return el.classList.add('printed');
  el.style.setProperty('--mask', masks[0]);
  printIO.observe(el);
});

/* ---------- final dithered wordmark ---------- */
const wm = document.getElementById('wordmark');
const drawWordmark = () => wm && ditherInto(wm, (o, w, h) => {
  const g = o.createLinearGradient(0, h * 0.15, 0, h * 0.9);
  g.addColorStop(0, '#000'); g.addColorStop(0.55, '#000'); g.addColorStop(1, '#8a8a8a');
  o.fillStyle = g;
  o.font = `700 ${Math.round(h * 0.78)}px "Hanken Grotesk", sans-serif`;
  o.textAlign = 'center'; o.textBaseline = 'middle';
  o.fillText('Capipaste', w / 2, h * 0.52);
}, { cell: 5 });
document.fonts.ready.then(drawWordmark);

/* ---------- final section: dithered bubbles drifting up ---------- */
(function bubbles() {
  const c = document.getElementById('bubbles');
  if (!c) return;
  const cell = 6; // one dither dot per 6 css px
  let w, h, ctx, off, o;
  const list = [];
  function size() {
    const r = c.getBoundingClientRect();
    w = Math.ceil(r.width / cell); h = Math.ceil(r.height / cell);
    c.width = w * cell; c.height = h * cell;
    ctx = c.getContext('2d');
    off = document.createElement('canvas'); off.width = w; off.height = h;
    o = off.getContext('2d', { willReadFrequently: true });
  }
  function spawn(anywhere) {
    const r = 2.5 + Math.random() * 6;
    return { x: Math.random() * w, y: anywhere ? Math.random() * h : h + r + Math.random() * 10,
             r, v: 0.05 + Math.random() * 0.12, sway: Math.random() * 6.28, amp: 0.3 + Math.random() * 1.2 };
  }
  size();
  for (let i = 0; i < Math.round(w * h / 420); i++) list.push(spawn(true));
  new ResizeObserver(size).observe(c);
  let visible = false;
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(c);
  let t = 0;
  function frame() {
    requestAnimationFrame(frame);
    if (!visible && t > 0) return;
    t++;
    o.fillStyle = '#fff'; o.fillRect(0, 0, w, h);
    for (const b of list) {
      if (!reduced) { b.y -= b.v; b.x += Math.sin(t * 0.02 + b.sway) * 0.02 * b.amp; }
      if (b.y < -b.r * 2) Object.assign(b, spawn(false));
      // soap bubble: light body, darker rim, bright highlight; fade out near the top
      const fade = Math.min(1, b.y / (h * 0.45));
      const g = o.createRadialGradient(b.x - b.r * .35, b.y - b.r * .35, b.r * .1, b.x, b.y, b.r);
      g.addColorStop(0, `rgba(255,255,255,${fade})`);
      g.addColorStop(0.72, `rgba(236,236,236,${fade})`);
      g.addColorStop(1, `rgba(60,60,60,${0.85 * fade})`);
      o.fillStyle = g;
      o.beginPath(); o.arc(b.x, b.y, b.r, 0, Math.PI * 2); o.fill();
    }
    const px = o.getImageData(0, 0, w, h).data;
    ctx.clearRect(0, 0, c.width, c.height);
    ctx.fillStyle = 'rgba(23,23,26,.34)';
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      if (px[(y * w + x) * 4] / 255 < (BAYER[y % 4][x % 4] + 0.5) / 16) ctx.fillRect(x * cell, y * cell, cell - 1, cell - 1);
    }
    if (reduced) return;
  }
  frame();
})();

/* ---------- shortcut keys: press in sequence ---------- */
(function pressKeys() {
  const combos = [...document.querySelectorAll('.combo')];
  if (!combos.length || reduced) return;
  let i = 0;
  setInterval(() => {
    const combo = combos[i++ % combos.length];
    combo.querySelectorAll('kbd').forEach((k, n) => {
      setTimeout(() => k.classList.add('down'), n * 90);
      setTimeout(() => k.classList.remove('down'), 520 + n * 60);
    });
  }, 900);
})();

/* ---------- section titles: dithered pixel lettering, solid ink ---------- */
// The real text stays in the DOM (transparent) for layout, selection and screen readers;
// a canvas on top redraws the same lines as Bayer-dithered dots.
function drawTitles() {
  const dpr = devicePixelRatio || 1;
  document.querySelectorAll('.dither-title').forEach(h => {
    const cs = getComputedStyle(h);
    const size = parseFloat(cs.fontSize);
    const lineH = parseFloat(cs.lineHeight) || size * 1.02;
    const box = h.getBoundingClientRect();
    // one dot ≈ size/18 css px, snapped to whole device pixels
    const cell = Math.max(2, Math.round(size / 16 * dpr));
    // extra room below for descenders, which the text box clips
    const cssW = box.width, cssH = box.height + size * 0.25;
    let c = h.querySelector('canvas');
    if (!c) { c = document.createElement('canvas'); c.setAttribute('aria-hidden', 'true'); h.appendChild(c); }
    c.width = Math.ceil(cssW * dpr / cell) * cell;
    c.height = Math.ceil(cssH * dpr / cell) * cell;
    c.style.width = `${c.width / dpr}px`;
    c.style.height = `${c.height / dpr}px`;

    // lay the text out exactly as the browser wrapped it: one rect per rendered line
    const range = document.createRange();
    const textNode = [...h.childNodes].find(n => n.nodeType === 3);
    if (!textNode) return;
    const text = textNode.textContent;
    const lines = [];
    let start = 0, lastTop = null;
    for (let i = 0; i < text.length; i++) {
      range.setStart(textNode, i); range.setEnd(textNode, i + 1);
      const r = range.getClientRects()[0];
      if (!r) continue;
      if (lastTop !== null && Math.abs(r.top - lastTop) > size * 0.5) {
        lines.push({ text: text.slice(start, i) });
        start = i;
      }
      lastTop = r.top;
    }
    lines.push({ text: text.slice(start) });

    ditherInto(c, (o, w, hgt) => {
      const scale = dpr / cell; // css px → low-res dots
      o.fillStyle = '#000';
      o.font = `${cs.fontWeight} ${size * scale}px ${cs.fontFamily}`;
      o.letterSpacing = `${parseFloat(cs.letterSpacing || 0) * scale}px`;
      o.textBaseline = 'alphabetic';
      lines.forEach((line, n) => {
        const baseline = (n * lineH + (lineH - size) / 2 + size * 0.8) * scale;
        o.fillText(line.text.trimEnd(), 0, baseline);
      });
    }, { cell, color: INK, threshold: 0.6 });
    h.classList.add('ready');
  });
}
document.fonts.ready.then(drawTitles);
let titleWidth = innerWidth;
addEventListener("resize", () => { if (innerWidth !== titleWidth) { titleWidth = innerWidth; drawTitles(); } });
