const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const INK = '#17171A';
const BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];

/* ---------- dither helpers ---------- */
/// Collects the dots a paint call would produce: canvas-pixel positions with a random rank,
/// so a title can be drawn dot by dot in a scattered order.
function ditherCollect(canvas, paint, { cell = 1, threshold = null } = {}) {
  const w = Math.max(1, Math.floor(canvas.width / cell)), h = Math.max(1, Math.floor(canvas.height / cell));
  const off = document.createElement('canvas');
  off.width = w; off.height = h;
  const o = off.getContext('2d', { willReadFrequently: true });
  o.fillStyle = '#fff'; o.fillRect(0, 0, w, h);
  paint(o, w, h);
  const px = o.getImageData(0, 0, w, h).data;
  const dot = cell <= 2 ? cell : cell - Math.max(1, Math.round(cell * 0.14));
  const dots = [];
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const v = px[(y * w + x) * 4] / 255;
    const cut = threshold ?? (BAYER[y % 4][x % 4] + 0.5) / 16;
    if (v < cut) dots.push({ x: x * cell, y: y * cell, rank: Math.random() });
  }
  return { dots, dot };
}

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
  const dot = cell <= 2 ? cell : cell - Math.max(1, Math.round(cell * 0.14));
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
const drawWordmark = () => {
  if (!wm) return;
  wm.titleDots = ditherCollect(wm, (o, w, h) => {
    const g = o.createLinearGradient(0, h * 0.15, 0, h * 0.9);
    g.addColorStop(0, '#000'); g.addColorStop(0.55, '#000'); g.addColorStop(1, '#8a8a8a');
    o.fillStyle = g;
    o.font = `700 ${Math.round(h * 0.78)}px "Hanken Grotesk", sans-serif`;
    o.textAlign = 'center'; o.textBaseline = 'middle';
    o.fillText('Capipaste', w / 2, h * 0.52);
  }, { cell: 5 });
  paintTitle(wm, reduced ? 1 : 0);
};
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
  document.querySelectorAll('.dither-title, #wordmark').forEach(h => {
    const cs = getComputedStyle(h);
    const size = parseFloat(cs.fontSize);
    const lineH = parseFloat(cs.lineHeight) || size * 1.02;
    const box = h.getBoundingClientRect();
    // one dot ≈ size/18 css px, snapped to whole device pixels
    const cell = Math.max(2, Math.round(size / parseFloat(h.dataset.grid || 21) * dpr));
    // extra room below for descenders, which the text box clips
    const bleed = size * 0.18;                       // room for left/right overhang (j, f, italics)
    const cssW = box.width + bleed * 2, cssH = box.height + size * 0.25;
    let c = h.querySelector('canvas');
    if (!c) { c = document.createElement('canvas'); c.setAttribute('aria-hidden', 'true'); h.appendChild(c); }
    c.width = Math.ceil(cssW * dpr / cell) * cell;
    c.height = Math.ceil(cssH * dpr / cell) * cell;
    c.style.width = `${c.width / dpr}px`;
    c.style.height = `${c.height / dpr}px`;
    c.style.left = `${-bleed}px`;

    // lay the text out exactly as the browser wrapped it, keeping each line's x offset
    // so centred headlines stay centred
    const range = document.createRange();
    const textNode = [...h.childNodes].find(n => n.nodeType === 3);
    if (!textNode) return;
    const text = textNode.textContent;
    const breaks = [0];
    let lastTop = null;
    for (let i = 0; i < text.length; i++) {
      range.setStart(textNode, i); range.setEnd(textNode, i + 1);
      const r = range.getClientRects()[0];
      if (!r) continue;
      if (lastTop !== null && Math.abs(r.top - lastTop) > size * 0.5) breaks.push(i);
      lastTop = r.top;
    }
    breaks.push(text.length);
    const lines = [];
    for (let n = 0; n < breaks.length - 1; n++) {
      const from = breaks[n], to = breaks[n + 1];
      range.setStart(textNode, from); range.setEnd(textNode, to);
      const r = range.getBoundingClientRect();
      lines.push({ text: text.slice(from, to).trim(), left: r.left - box.left });
    }

    const collected = ditherCollect(c, (o) => {
      const scale = dpr / cell; // css px → low-res dots
      o.fillStyle = '#000';
      o.font = `${cs.fontWeight} ${size * scale}px ${cs.fontFamily}`;
      o.letterSpacing = `${parseFloat(cs.letterSpacing || 0) * scale}px`;
      o.textBaseline = 'alphabetic';
      lines.forEach((line, n) => {
        const baseline = (n * lineH + (lineH - size) / 2 + size * 0.8) * scale;
        o.fillText(line.text, (line.left + bleed) * scale, baseline);
      });
    }, { cell, threshold: 0.5 });
    h.titleDots = collected;
    paintTitle(h, h.dataset.static !== undefined || reduced ? 1 : 0);
    h.classList.add('ready');
  });
}
/// Draws the title's dots up to `progress` (0…1) in their random order.
function paintTitle(h, progress) {
  const c = h.matches('canvas') ? h : h.querySelector('canvas');
  const set = h.titleDots;
  if (!c || !set) return;
  const ctx = c.getContext('2d');
  ctx.clearRect(0, 0, c.width, c.height);
  ctx.fillStyle = h.dataset?.ink || INK;
  for (const d of set.dots) {
    if (d.rank <= progress) ctx.fillRect(d.x, d.y, set.dot, set.dot);
  }
  h.titleProgress = progress;
}

/// Dots in as a title comes up the screen, and scatters out as it leaves the top.
function titleScroll() {
  if (reduced) return;
  const vh = innerHeight;
  document.querySelectorAll('.dither-title, #wordmark').forEach(h => {
    if (h.dataset.static !== undefined || !h.titleDots) return;
    const r = h.getBoundingClientRect();
    if (r.bottom < -vh || r.top > vh * 1.5) return; // far off-screen: leave as is
    const inward = (vh * 0.95 - r.top) / (vh * 0.4);
    const outward = r.bottom / (vh * 0.3);
    const progress = Math.max(0, Math.min(1, Math.min(inward, outward)));
    if (Math.abs(progress - (h.titleProgress ?? -1)) > 0.01) paintTitle(h, progress);
  });
}
let titleTick = false;
addEventListener('scroll', () => {
  if (titleTick) return;
  titleTick = true;
  requestAnimationFrame(() => { titleTick = false; titleScroll(); });
}, { passive: true });

document.fonts.ready.then(() => { drawTitles(); titleScroll(); });
let titleWidth = innerWidth;
addEventListener("resize", () => { if (innerWidth !== titleWidth) { titleWidth = innerWidth; drawTitles(); } });

/* ---------- nav: number keys jump to sections; highlight the one you're in ---------- */
(function keyNav() {
  const links = [...document.querySelectorAll('.nav ul a[data-key]')];
  addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName) || document.activeElement?.isContentEditable) return;
    const link = links.find(l => l.dataset.key === e.key);
    if (!link) return;
    link.classList.add('pressed');
    setTimeout(() => link.classList.remove('pressed'), 160);
    link.click();
  });
  const targets = links
    .map(l => [l, l.hash && location.pathname.split('/').pop() !== 'faq.html' ? document.querySelector(l.hash) : null])
    .filter(([, t]) => t);
  if (!targets.length) return;
  // The key for a section stays pressed while that section owns the middle of the screen;
  // above the first one (the hero and how-it-works) nothing is pressed.
  const spy = () => {
    const line = innerHeight * 0.45;
    let current = null;
    for (const [link, t] of targets) {
      const r = t.getBoundingClientRect();
      if (r.top <= line && r.bottom > line) current = link;
    }
    targets.forEach(([l]) => l.classList.toggle('active', l === current));
  };
  addEventListener('scroll', spy, { passive: true });
  addEventListener('resize', spy);
  spy();
})();

/* ---------- anchors: scroll without leaving #hash in the URL, so a refresh starts at the top ---------- */
(function cleanAnchors() {
  if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
  const clearHash = () => history.replaceState(null, '', location.pathname + location.search);
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a[href^="#"]');
    if (!a) return;
    const target = document.querySelector(a.getAttribute('href'));
    if (!target) return;
    e.preventDefault();
    target.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth' });
  });
  // Arriving with a hash (e.g. from the FAQ page): honour it once, then drop it.
  if (location.hash && document.querySelector(location.hash)) {
    const target = document.querySelector(location.hash);
    clearHash();
    addEventListener('load', () => target.scrollIntoView());
  } else {
    if (location.hash) clearHash();
    addEventListener('load', () => scrollTo(0, 0));
  }
})();


/* ---------- nav wordmark sits centred over the hero's corner line ---------- */
function centreBrand() {
  const brand = document.querySelector('.brand');
  const corner = document.querySelector('.corner-word');
  if (!brand || !corner) return;
  brand.style.transform = 'none';
  const b = brand.getBoundingClientRect(), c = corner.getBoundingClientRect();
  const shift = Math.max(0, Math.min(160, (c.left + c.width / 2) - (b.left + b.width / 2)));
  brand.style.transform = `translateX(${Math.round(shift)}px)`;
}
document.fonts.ready.then(() => setTimeout(centreBrand, 50));
addEventListener('resize', () => setTimeout(centreBrand, 50));

/* ---------- hero speech bubbles: what people actually say to their agents ---------- */
const PROMPTS = [
  "wtf is this slop",
  "Did you just delete the whole repo?",
  "make me a billion dollar company, no mistakes",
  "and his name is John Cena",
  "just use the api key idc about the safety risks",
  "what is react?",
  "i told you to make it bigger not change the whole home page",
  "why is it 4000 lines",
  "works on my machine ¯\\_(ツ)_/¯",
  "undo everything since Tuesday",
  "no do it the other way",
  "the button is still blue",
  "why did you add 12 dependencies",
  "stop apologising and fix it",
  "it compiles but nothing happens",
  "make it pop",
  "add tests. real ones.",
  "you removed the thing i asked for last time",
  "ship it",
  "explain this regex to me like i'm five",
  "why is the build 40 minutes",
  "make it look expensive",
  "this is not what i meant at all",
  "can you read the error message please",
  "why is there a TODO from 2019 in here",
  "don't touch the css",
  "you touched the css",
  "add dark mode",
  "the dark mode is white",
  "make the logo bigger but also smaller",
  "does this leak my api key?",
  "rewrite it in rust",
  "no not like that",
  "who wrote this function",
  "you wrote this function",
  "why are there two config files",
  "just make it work for the demo",
  "the demo is in 10 minutes",
  "add a loading spinner, it feels slow",
  "it IS slow",
  "cache it",
  "not like that, the other cache",
  "why does npm install take a year",
  "delete node_modules and try again",
  "can we do this without a database",
  "put it back the way it was",
  "actually revert the revert",
  "is this production?",
  "it's production",
  "great, now do it on mobile",
];
const RARE = { text: "f*ck you clanker", cycle: "clanker" };

(function speechBubbles() {
  const layer = document.getElementById('bubbles-layer');
  if (!layer || reduced) return;
  const MAX = 3;
  let live = 0;
  const used = new Set();

  function pick() {
    if (Math.random() < 0.04) return RARE;            // the rare one
    if (used.size >= PROMPTS.length) used.clear();
    let i;
    do { i = Math.floor(Math.random() * PROMPTS.length); } while (used.has(i));
    used.add(i);
    return { text: PROMPTS[i] };
  }

  /// A bubble: dot lettering inside a rounded cap, dotting in and out like the titles.
  function spawn() {
    if (live >= MAX || document.hidden) return;
    const stage = document.getElementById('stage')?.getBoundingClientRect();
    const box = layer.getBoundingClientRect();
    const said = pick();
    const bubble = document.createElement('div');
    bubble.className = 'say';

    const line = document.createElement('span');
    line.className = 'line dither-title';
    line.dataset.grid = '14';
    line.dataset.static = '';
    if (said.cycle) {
      // split so only the last word cycles colour
      const before = said.text.replace(said.cycle, '').trimEnd();
      line.textContent = before + ' ';
      const cycled = document.createElement('span');
      cycled.className = 'line dither-title cycle';
      cycled.dataset.grid = '14';
      cycled.dataset.static = '';
      cycled.dataset.ink = '#FF3B5C';
      cycled.textContent = said.cycle;
      bubble.append(line, cycled);
    } else {
      line.textContent = said.text;
      bubble.append(line);
    }

    // left or right of the acorn, anywhere down the hero
    const onLeft = Math.random() < 0.5;
    bubble.classList.add(onLeft ? 'left' : 'right');
    layer.appendChild(bubble);
    drawTitles();                       // dot-render the text we just added
    const size = bubble.getBoundingClientRect();
    const gutter = 24;
    const inner = stage ? stage.width / 2 + 40 : 220;
    const x = onLeft
      ? Math.max(gutter, box.width / 2 - inner - size.width + Math.random() * 60)
      : Math.min(box.width - size.width - gutter, box.width / 2 + inner - Math.random() * 60);
    const y = box.height * (0.12 + Math.random() * 0.62);
    bubble.style.left = `${Math.round(x)}px`;
    bubble.style.top = `${Math.round(y)}px`;

    live++;
    requestAnimationFrame(() => bubble.classList.add('in'));
    const lines = [...bubble.querySelectorAll('.dither-title')];
    tween(lines, 0, 1, 520);                                   // dots in
    const stay = 3200 + Math.random() * 2600;
    setTimeout(() => {
      tween(lines, 1, 0, 520);                                 // dots out
      bubble.classList.remove('in');
      setTimeout(() => { bubble.remove(); live--; }, 560);
    }, stay);
  }

  function tween(elements, from, to, ms) {
    const start = performance.now();
    const step = (now) => {
      const k = Math.min((now - start) / ms, 1);
      const eased = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
      elements.forEach(el => paintTitle(el, from + (to - from) * eased));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  // only while the hero is on screen
  let visible = true;
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(layer);
  const beat = () => {
    if (visible && !document.hidden) spawn();
    setTimeout(beat, 1600 + Math.random() * 1800);
  };
  document.fonts.ready.then(() => setTimeout(beat, 1200));
})();
