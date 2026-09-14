// HLDGen Figma Plugin — code.js
// Reads HLDGen JSON (one per scene) and creates screen frames, wireframes,
// sticky notes, API clouds, and connectors in Figma.

figma.showUI(__html__, { width: 340, height: 440, title: "HLDGen — Scene Importer" });

// ── Palette ──────────────────────────────────────────────────────────────────
const C = {
  bg:         { r: 0.09, g: 0.09, b: 0.16 },
  surface:    { r: 0.13, g: 0.14, b: 0.22 },
  surface2:   { r: 0.17, g: 0.18, b: 0.27 },
  border:     { r: 0.24, g: 0.27, b: 0.40 },
  text:       { r: 0.78, g: 0.81, b: 0.87 },
  textDim:    { r: 0.38, g: 0.41, b: 0.50 },
  textHead:   { r: 0.91, g: 0.92, b: 0.96 },
  accent:     { r: 0.30, g: 0.56, b: 1.00 },   // blue — internal nav
  green:      { r: 0.18, g: 0.83, b: 0.63 },   // API calls
  amber:      { r: 0.96, g: 0.77, b: 0.09 },   // external destination / ghost
  red:        { r: 0.91, g: 0.34, b: 0.42 },   // exit / dismiss
  pink:       { r: 0.95, g: 0.28, b: 0.60 },   // external nav (cross-module)
  white:      { r: 1,    g: 1,    b: 1    },
};

function solid(c, a = 1) { return [{ type: 'SOLID', color: c, opacity: a }]; }
function noFill()         { return []; }

// ── Layout constants ──────────────────────────────────────────────────────────
const CARD_W      = 220;
const CARD_H      = 320;
const CARD_GAP    = 200;   // wider gap so arrows have room
const STICKY_W    = 190;
const STICKY_H    = 90;    // tall card-style stickies
const STICKY_GAP  = 12;
const API_CLOUD_H = 70;
const GHOST_W     = 200;
const GHOST_H     = 90;

figma.ui.onmessage = async (msg) => {
  if (msg.type !== 'generate') return;

  try {
    await loadFonts();
    const scenes = msg.scenes;

    // Match the HTML artifact's dark-navy canvas background

    const vcToFrame = new Map();   // vcClassName → screen card frame
    const cards     = [];          // { scene, frame, vcName, col }

    // ── Pass 1: create all screen cards ──────────────────────────────────────
    for (let col = 0; col < scenes.length; col++) {
      const scene = scenes[col];
      const x = col * (CARD_W + CARD_GAP);
      const frame = await buildScreenCard(scene, x, 0);
      figma.currentPage.appendChild(frame);

      const vcName = (scene.viewControllers || [])[0] || `Scene${col}`;
      vcToFrame.set(vcName, frame);
      cards.push({ scene, frame, vcName, col });
    }

    // ── Pass 2: create sticky notes, track them for connectors ───────────────
    const stickyRecords = [];   // { sticky, chain, sourceFrame }
    const ghostCards    = new Map();  // destKey → ghost frame

    for (const { scene, frame } of cards) {
      const actions = (scene.actionChains || []).filter(a => {
        // Skip pure lifecycle / setup boilerplate with no user-visible consequence
        const name = (a.action || '').toLowerCase();
        if (/^bind(ing)?$|^awakeFromNib$|^viewDidLayoutSubviews$|^prepareForReuse$|^setupHeaderData$/.test(name)) return false;
        // Always keep recognisable user interactions (taps, swipes, gestures)
        if (/\.rx\.tap|button|tap|gesture|swipe|select|press|click/i.test(a.action)) return true;
        // Keep if has any destination, route, or API call (even "next queued" is worth showing)
        const hasDest = (a.resolvedDestinations || []).length > 0;
        const hasRoute = (a.vcRoutes || []).length > 0;
        const hasApi = (a.calls || []).some(c => c.services && c.services.length > 0);
        return hasDest || hasRoute || hasApi;
      });

      const endpoints = scene.apiEndpoints || [];
      const serviceCalls = (scene.actionChains || [])
        .flatMap(a => (a.calls || []).flatMap(c => c.services || []));

      let stickyY = frame.y + CARD_H + 20;

      for (const chain of actions) {
        const dest = [...(chain.resolvedDestinations || []), ...(chain.vcRoutes || [])][0] || '';
        const isExternal = dest && !findFrameForDest(dest, vcToFrame) &&
                           !dest.includes('exits') && !dest.includes('completes');

        const sticky = await buildSticky(chain, isExternal, STICKY_W);
        sticky.x = frame.x + (CARD_W - STICKY_W) / 2;
        sticky.y = stickyY;
        figma.currentPage.appendChild(sticky);
        stickyRecords.push({ sticky, chain, sourceFrame: frame });
        stickyY += STICKY_H + STICKY_GAP;
      }

      if (endpoints.length > 0 || serviceCalls.length > 0) {
        const cloud = await buildApiCloud(endpoints, serviceCalls, CARD_W);
        cloud.x = frame.x;
        cloud.y = stickyY + 8;
        figma.currentPage.appendChild(cloud);
      }
    }

    // ── Pass 3: draw arrows sticky → destination (vector lines, not connectors) ─
    const rightmostX = Math.max(...cards.map(c => c.frame.x)) + CARD_W + CARD_GAP;
    let ghostRow = 0;
    let arrowCount = 0;

    // Destinations we never draw arrows for — not meaningful on an HLD diagram
    function shouldSkipDest(dest) {
      return !dest
        || dest.includes('next queued')
        || dest.includes('exits')
        || dest.includes('completes')
        || dest.includes('closes flow')
        || dest.includes('pops to root');
    }

    for (const { sticky, chain, sourceFrame } of stickyRecords) {
      const dests = [...(chain.resolvedDestinations || []), ...(chain.vcRoutes || [])];
      if (dests.length === 0) continue;

      for (const dest of dests) {
        if (shouldSkipDest(dest)) continue;

        const targetFrame = findFrameForDest(dest, vcToFrame);

        if (targetFrame && targetFrame !== sourceFrame) {
          const arrow = buildArrow(sticky, targetFrame, C.accent);
          if (arrow) { figma.currentPage.appendChild(arrow); arrowCount++; }
        } else if (!targetFrame) {
          // Only create a ghost card for genuinely external VCs (not flow internals)
          const ghostKey = dest.trim();
          if (!ghostCards.has(ghostKey)) {
            const ghost = await buildGhostCard(dest);
            ghost.x = rightmostX;
            ghost.y = ghostRow * (GHOST_H + 28);
            figma.currentPage.appendChild(ghost);
            ghostCards.set(ghostKey, ghost);
            ghostRow++;
          }
          const arrow = buildArrow(sticky, ghostCards.get(ghostKey), C.pink);
          if (arrow) { figma.currentPage.appendChild(arrow); arrowCount++; }
        }
      }
    }

    figma.viewport.scrollAndZoomIntoView(cards.map(c => c.frame));
    figma.ui.postMessage({ type: 'done', detail: `${scenes.length} screens · ${arrowCount} arrows · ${ghostCards.size} external` });
  } catch (e) {
    figma.ui.postMessage({ type: 'error', detail: String(e) });
  }
};

// ── Build a complete screen card (no stickies — handled in main loop) ─────────
async function buildScreenCard(scene, x, y) {
  const vcName    = (scene.viewControllers || [])[0] || 'Screen';
  const shortName = vcName.replace('ViewController', '');

  const card = figma.createFrame();
  card.name = vcName;
  card.resize(CARD_W, CARD_H);
  card.x = x; card.y = y;
  card.fills = solid(C.surface);
  card.strokes = [{ type: 'SOLID', color: C.border }];
  card.strokeWeight = 1;
  card.cornerRadius = 10;
  card.clipsContent = true;

  // Title bar
  const bar = figma.createFrame();
  bar.name = 'title-bar';
  bar.resize(CARD_W, 32);
  bar.x = 0; bar.y = 0;
  bar.fills = solid(C.surface2);
  card.appendChild(bar);

  const dot = figma.createEllipse();
  dot.resize(7, 7);
  dot.x = 10; dot.y = 12;
  dot.fills = solid(C.accent);
  bar.appendChild(dot);

  const nameT = figma.createText();
  nameT.fontName = { family: 'Inter', style: 'Semi Bold' };
  nameT.fontSize = 9;
  nameT.characters = shortName;
  nameT.fills = solid(C.textHead);
  nameT.x = 22; nameT.y = 10;
  bar.appendChild(nameT);

  // Wireframe body
  const body = figma.createFrame();
  body.name = 'wireframe';
  body.resize(CARD_W, CARD_H - 32);
  body.x = 0; body.y = 32;
  body.fills = solid(C.surface);
  card.appendChild(body);

  const xibs = scene.xibs || [];
  if (xibs.length > 0) {
    const nodes  = flattenNodes(xibs[0].nodes || []);
    const origW  = xibs[0].width  || 414;
    const origH  = xibs[0].height || 896;
    const sx     = (CARD_W - 16) / origW;
    const sy     = (CARD_H - 32 - 16) / origH;
    const scale  = Math.min(sx, sy);

    const renderedW = origW * scale;
    const renderedH = origH * scale;
    const offsetX = ((CARD_W) - renderedW) / 2;
    const offsetY = ((CARD_H - 32) - renderedH) / 2;

    for (const node of nodes) {
      if (node.type === 'view' && !node.label) continue;
      const el = await buildWfNode(node, scale);
      if (!el) continue;
      el.x = offsetX + node.x * scale;
      el.y = offsetY + node.y * scale;
      body.appendChild(el);
    }
  } else {
    const placeholder = figma.createRectangle();
    placeholder.resize(CARD_W - 20, CARD_H - 32 - 20);
    placeholder.x = 10; placeholder.y = 10;
    placeholder.fills = solid(C.surface2);
    placeholder.cornerRadius = 4;
    body.appendChild(placeholder);

    const pt = figma.createText();
    pt.fontName = { family: 'Inter', style: 'Regular' };
    pt.fontSize = 9;
    pt.characters = 'no xib / storyboard found';
    pt.fills = solid(C.textDim);
    pt.x = 14; pt.y = 14;
    body.appendChild(pt);
  }

  return card;
}

// ── Flatten xib node tree ─────────────────────────────────────────────────────
function flattenNodes(nodes, depth = 0) {
  const out = [];
  for (const n of nodes) {
    if (n.type === 'view' && n.w > 380 && n.h > 400 && depth < 2) {
      out.push(...flattenNodes(n.children || [], depth + 1));
    } else {
      out.push(n);
      if (n.children && n.children.length > 0) {
        out.push(...flattenNodes(n.children, depth + 1));
      }
    }
  }
  return out;
}

// ── Build a wireframe element from a xib node ─────────────────────────────────
async function buildWfNode(node, scale) {
  const w = Math.max(node.w * scale, 4);
  const h = Math.max(node.h * scale, 4);
  const fillColor = hexToRgb(node.color) || C.surface2;

  if (node.type === 'button') {
    const f = figma.createFrame();
    f.name = node.label || 'button';
    f.resize(w, Math.max(h, 18));
    f.fills = solid(fillColor, 0.2);
    f.strokes = [{ type: 'SOLID', color: fillColor }];
    f.strokeWeight = 1;
    f.cornerRadius = 3;

    const t = figma.createText();
    t.fontName = { family: 'Inter', style: 'Semi Bold' };
    t.fontSize = Math.max(7, Math.min(9, h * 0.5));
    t.characters = truncate(node.label || 'button', 20);
    t.fills = solid(fillColor);
    t.textAlignHorizontal = 'CENTER';
    t.resize(w - 4, t.height);
    t.x = 2; t.y = Math.max(2, (Math.max(h, 18) - t.height) / 2);
    f.appendChild(t);
    return f;
  }

  if (node.type === 'label') {
    const t = figma.createText();
    t.fontName = { family: 'Inter', style: 'Regular' };
    t.fontSize = Math.max(7, Math.min(9, h * 0.55));
    t.characters = truncate(node.label || '', 30);
    t.fills = solid(fillColor);
    t.resize(Math.max(w, 30), t.height);
    return t;
  }

  if (node.type === 'image') {
    const r = figma.createRectangle();
    r.name = 'image';
    r.resize(w, h);
    r.fills = solid(fillColor, 0.15);
    r.strokes = [{ type: 'SOLID', color: fillColor }];
    r.strokeWeight = 1;
    r.dashPattern = [3, 3];
    r.cornerRadius = 3;
    return r;
  }

  if (node.type === 'list' || node.type === 'scroll' || node.type === 'stack') {
    const r = figma.createRectangle();
    r.name = node.type;
    r.resize(w, h);
    r.fills = solid(fillColor, 0.08);
    r.strokes = [{ type: 'SOLID', color: fillColor }];
    r.strokeWeight = 1;
    r.cornerRadius = 3;
    return r;
  }

  const r = figma.createRectangle();
  r.name = node.label || node.type;
  r.resize(w, h);
  r.fills = solid(fillColor, 0.06);
  r.strokes = [{ type: 'SOLID', color: C.border }];
  r.strokeWeight = 1;
  r.cornerRadius = 2;
  return r;
}

// ── Build sticky note (large card style, like HTML whiteboard) ────────────────
async function buildSticky(chain, isExternal, cardW) {
  const isApi      = (chain.calls || []).some(c => c.services && c.services.length);
  const isExit     = (chain.resolvedDestinations || []).some(d => d.includes('exits') || d.includes('completes'));
  const isCallback = /success|complete|finish|done|result|callback/i.test(chain.action);

  // Vivid solid fills matching HTML whiteboard colors
  const color = isApi      ? C.green
              : isExit     ? C.red
              : isExternal ? C.pink
              : isCallback ? C.amber
              :              C.accent;

  const dest = [...(chain.resolvedDestinations || []), ...(chain.vcRoutes || [])][0] || '';
  const svc  = (chain.calls || []).flatMap(c => c.services || [])[0] || '';

  // Detect action kind for the type label
  const kindLabel = isApi ? 'API' : isExit ? 'EXIT' : /tap|button|press/i.test(chain.action) ? 'TAP' : 'BIND';

  const f = figma.createFrame();
  f.name = `sticky:${chain.action}`;
  f.resize(cardW, STICKY_H);
  f.fills = solid(color, 0.85);   // vivid, mostly-opaque fill
  f.cornerRadius = 6;
  f.clipsContent = false;

  // Top kind badge row
  const badge = figma.createFrame();
  badge.name = 'kind';
  badge.resize(cardW, 20);
  badge.x = 0; badge.y = 0;
  badge.fills = solid(color);   // fully opaque top stripe
  badge.cornerRadius = 6;
  f.appendChild(badge);

  const kindT = figma.createText();
  kindT.fontName = { family: 'Inter', style: 'Semi Bold' };
  kindT.fontSize = 8;
  kindT.letterSpacing = { value: 1.5, unit: 'PIXELS' };
  kindT.characters = kindLabel;
  kindT.fills = solid(C.white);
  kindT.x = 8; kindT.y = 5;
  badge.appendChild(kindT);

  // Action name
  const label = figma.createText();
  label.fontName = { family: 'Inter', style: 'Semi Bold' };
  label.fontSize = 11;
  label.characters = `'${truncate(chain.action, 22)}'`;
  label.fills = solid(C.white);
  label.x = 8; label.y = 26;
  f.appendChild(label);

  // Destination / service subtitle
  if (dest || svc) {
    const sub = figma.createText();
    sub.fontName = { family: 'Inter', style: 'Regular' };
    sub.fontSize = 9;
    sub.characters = '→ ' + truncate(
      (dest || svc)
        .replace('ViewController', 'VC')
        .replace(' screen', '')
        .replace('flow completes (returns to caller / exits module)', 'exits module'),
      32
    );
    sub.fills = solid(C.white, 0.85);
    sub.x = 8; sub.y = 44;
    f.appendChild(sub);
  }

  // Small arrow → on the right for nav stickies
  if (!isApi && !isExit && (dest || isExternal)) {
    const arr = figma.createText();
    arr.fontName = { family: 'Inter', style: 'Regular' };
    arr.fontSize = 14;
    arr.characters = '→';
    arr.fills = solid(C.white, 0.6);
    arr.x = cardW - 20; arr.y = (STICKY_H - 18) / 2;
    f.appendChild(arr);
  }

  return f;
}

// ── Build ghost card for external module reference ────────────────────────────
async function buildGhostCard(destName) {
  const shortName = destName
    .replace('ViewController', '')
    .replace('screen', '')
    .replace('exits module', 'exits')
    .trim();

  const f = figma.createFrame();
  f.name = `external:${shortName}`;
  f.resize(GHOST_W, GHOST_H);
  f.fills = solid(C.amber, 0.08);
  f.strokes = [{ type: 'SOLID', color: C.amber }];
  f.strokeWeight = 1.5;
  f.strokeAlign = 'INSIDE';
  f.cornerRadius = 8;
  f.dashPattern = [6, 4];

  // Badge
  const badge = figma.createFrame();
  badge.name = 'badge';
  badge.resize(60, 14);
  badge.x = GHOST_W - 68; badge.y = 8;
  badge.fills = solid(C.amber, 0.2);
  badge.cornerRadius = 3;
  f.appendChild(badge);

  const badgeT = figma.createText();
  badgeT.fontName = { family: 'Inter', style: 'Semi Bold' };
  badgeT.fontSize = 7;
  badgeT.characters = 'external';
  badgeT.fills = solid(C.amber);
  badgeT.x = 4; badgeT.y = 3;
  badge.appendChild(badgeT);

  const nameT = figma.createText();
  nameT.fontName = { family: 'Inter', style: 'Semi Bold' };
  nameT.fontSize = 11;
  nameT.characters = truncate(shortName, 28);
  nameT.fills = solid(C.amber);
  nameT.x = 10; nameT.y = 30;
  f.appendChild(nameT);

  const subT = figma.createText();
  subT.fontName = { family: 'Inter', style: 'Regular' };
  subT.fontSize = 8.5;
  subT.characters = '— not part of this module';
  subT.fills = solid(C.amber, 0.55);
  subT.x = 10; subT.y = 50;
  f.appendChild(subT);

  return f;
}

// ── Build API cloud ───────────────────────────────────────────────────────────
async function buildApiCloud(endpoints, services, cardW) {
  const lines = [
    ...endpoints.map(e => `${e.method || 'GET'} ${e.path || ''}`),
    ...services,
  ];

  const f = figma.createFrame();
  f.name = 'API cloud';
  f.resize(cardW, Math.max(API_CLOUD_H, 20 + lines.length * 14));
  f.fills = solid(C.green, 0.1);
  f.strokes = [{ type: 'SOLID', color: C.green }];
  f.strokeWeight = 1;
  f.strokeAlign = 'INSIDE';
  f.cornerRadius = 6;
  f.dashPattern = [4, 3];

  const header = figma.createText();
  header.fontName = { family: 'Inter', style: 'Semi Bold' };
  header.fontSize = 8;
  header.characters = '☁ API';
  header.fills = solid(C.green);
  header.x = 8; header.y = 8;
  f.appendChild(header);

  for (let i = 0; i < lines.length; i++) {
    const t = figma.createText();
    t.fontName = { family: 'Inter', style: 'Regular' };
    t.fontSize = 8;
    t.characters = lines[i];
    t.fills = solid(C.green, 0.8);
    t.x = 8; t.y = 22 + i * 14;
    f.appendChild(t);
  }

  return f;
}

// ── Build arrow line: fromNode right-edge → toNode left-edge ─────────────────
// Uses VectorNode with bezier curve.
//
// IMPORTANT: Figma normalises vectorNetwork so all vertex coords are ≥ 0.
// We must therefore express vertices in the bounding-box coordinate space
// (origin = top-left of the bounding box) and place the node at the bounding
// box top-left on the canvas. Mixing canvas and local coords causes arrows to
// appear at the wrong position or be invisible.
function buildArrow(fromNode, toNode, color) {
  const x1 = fromNode.x + fromNode.width;          // canvas: right edge of source
  const y1 = fromNode.y + fromNode.height / 2;     // canvas: centre of source
  const x2 = toNode.x;                              // canvas: left edge of dest
  const y2 = toNode.y + toNode.height / 2;          // canvas: centre of dest

  if (Math.abs(x2 - x1) + Math.abs(y2 - y1) < 2) return null;

  // Bounding box of the two endpoints on the canvas
  const bx = Math.min(x1, x2);
  const by = Math.min(y1, y2);

  // Local coordinates (all non-negative, relative to bounding box top-left)
  const lx1 = x1 - bx;
  const ly1 = y1 - by;
  const lx2 = x2 - bx;
  const ly2 = y2 - by;

  // Bezier tangents: depart/arrive horizontally for a smooth S-curve
  const tLen = Math.max(40, Math.abs(lx2 - lx1) * 0.4);
  const sign  = lx2 >= lx1 ? 1 : -1;
  const tStart = { x: sign * tLen, y: 0 };
  const tEnd   = { x: -sign * tLen, y: 0 };

  const vec = figma.createVector();
  vec.x = bx;
  vec.y = by;
  vec.fills = [];
  vec.strokes = [{ type: 'SOLID', color: color || C.accent }];
  vec.strokeWeight = 2;
  vec.vectorNetwork = {
    vertices: [
      { x: lx1, y: ly1, strokeCap: 'NONE',       strokeJoin: 'MITER', cornerRadius: 0, handleMirroring: 'NONE' },
      { x: lx2, y: ly2, strokeCap: 'ARROW_LINES', strokeJoin: 'MITER', cornerRadius: 0, handleMirroring: 'NONE' },
    ],
    segments: [{ start: 0, end: 1, tangentStart: tStart, tangentEnd: tEnd }],
    regions: [],
  };
  return vec;
}

// ── Destination → frame resolution ───────────────────────────────────────────
// dest examples: "HistoryRevokeViewController screen", "ScanQR", "next queued screen"
function findFrameForDest(dest, vcToFrame) {
  if (!dest || dest.includes('next queued') || dest.includes('exits') || dest.includes('completes')) return null;
  const destLow = dest.toLowerCase().replace(/\s+screen$/, '');
  for (const [vcName, frame] of vcToFrame) {
    // exact VC class name in dest string
    if (dest.includes(vcName)) return frame;
    // short name: strip ViewController + module prefix
    const short = vcName.replace('ViewController', '').toLowerCase();
    if (short.length > 2 && destLow.includes(short)) return frame;
    // reverse substring (e.g. destToken="scanqr" ⊂ short="qrscanner" fails,
    // but word-parts of dest each checked: "scan" ⊂ "qrscanner" ✓)
    const destClean = destLow.replace(/[^a-z]/g, '');
    if (destClean.length > 2 && short.includes(destClean)) return frame;
    // split dest into camelCase / word parts and check each against short name
    const parts = dest.replace(/([A-Z])/g, ' $1').toLowerCase().split(/\s+/).filter(p => p.length > 2);
    if (parts.some(p => short.includes(p))) return frame;
  }
  return null;
}

// ── Font loader ───────────────────────────────────────────────────────────────
async function loadFonts() {
  await Promise.all([
    figma.loadFontAsync({ family: 'Inter', style: 'Regular' }),
    figma.loadFontAsync({ family: 'Inter', style: 'Semi Bold' }),
  ]);
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function hexToRgb(hex) {
  if (!hex || !hex.startsWith('#')) return null;
  const n = parseInt(hex.slice(1), 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 };
}

function truncate(str, max) {
  return str.length > max ? str.slice(0, max - 1) + '…' : str;
}
