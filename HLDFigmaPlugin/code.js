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
// Wide enough that a real endpoint path stays readable without truncation.
const CARD_W      = 300;
const CARD_H      = 320;
const CARD_GAP    = 140;
const PANEL_GAP     = 12;
const PANEL_HEAD_H  = 24;
const PANEL_PAD     = 10;
const ROW_H         = 14;
const API_ROW_H     = 27;   // endpoint line plus its request/response line
const MAX_NAV_ROWS  = 8;
const MAX_API_ROWS  = 6;
const MAX_COLS       = 6;    // screens per row before a journey wraps
const JOURNEY_COLS   = 3;    // journey blocks packed side by side
const ROW_GAP        = 90;
const GROUP_PAD      = 56;   // breathing room inside a journey boundary
const GROUP_GAP      = 150;  // vertical space between journeys
const GROUP_LABEL_H  = 44;

figma.ui.onmessage = async (msg) => {
  if (msg.type !== 'generate') return;

  try {
    await loadFonts();
    const scenes = msg.scenes;

    // Match the HTML artifact's dark-navy canvas background

    // Every run appended to whatever was already on the page, so two or three generates
    // stacked their output on top of each other — old ghost cards and arrows included.
    // Nodes are tagged on creation, so a re-run clears only what this plugin made.
    for (const node of figma.currentPage.children.slice()) {
      if (node.getPluginData('hldgen') === '1') node.remove();
    }

    // ── Pass 0: split scenes into journeys ───────────────────────────────────
    // A module's 99 screens laid out as one row is unreadable. `scene.group` is the folder
    // under Scenes/ (AddMoney, Settings, PlayCard…), which is the journey a reader thinks in.
    const journeys = new Map();   // groupName → scene[]
    for (const scene of scenes) {
      const g = scene.group || scene.module || 'Scenes';
      if (!journeys.has(g)) journeys.set(g, []);
      journeys.get(g).push(scene);
    }

    // ── Pass 1: resolve the navigation graph before anything is drawn ────────
    // Screens are placed in flow order, so which screen leads to which has to be known first.
    const vcToScene = new Map();
    for (const s of scenes) for (const v of (s.viewControllers || [])) vcToScene.set(v, s);

    const edges = new Map();        // "srcName->dstName" → { from, to, count }
    const externals = new Map();    // scene → Set(label)   destinations outside this journey
    for (const s of scenes) {
      for (const chain of visibleActions(s)) {
        for (const dest of [...(chain.resolvedDestinations || []), ...(chain.vcRoutes || [])]) {
          if (shouldSkipDest(dest)) continue;
          const short = dest.replace('ViewController', 'VC').replace(' screen', '').trim();
          const t = findFrameForDest(dest, vcToScene);   // map values are scenes here

          if (!externals.has(s)) externals.set(s, new Set());
          if (!t)                   { externals.get(s).add(short); continue; }
          if (t === s)              continue;                       // self-route, nothing to draw
          if (t.group !== s.group)  { externals.get(s).add(`${short} · ${t.group}`); continue; }

          const k = `${s.name}->${t.name}`;
          // Six buttons leading to the same screen is one relationship, not six arrows.
          if (edges.has(k)) edges.get(k).count++;
          else edges.set(k, { from: s, to: t, count: 1 });
        }
      }
    }

    // Same-journey destinations, named per screen for its "goes to" panel.
    const nextByScene = new Map();
    for (const { from, to } of edges.values()) {
      if (!nextByScene.has(from)) nextByScene.set(from, []);
      if (!nextByScene.get(from).includes(to.name)) nextByScene.get(from).push(to.name);
    }
    const navOf = s => nextByScene.get(s) || [];
    const extOf = s => [...(externals.get(s) || [])];

    // Order each journey so a screen comes after whatever leads into it, which keeps
    // arrows pointing forward and short instead of doubling back across the block.
    for (const [name, gs] of journeys) journeys.set(name, flowOrder(gs, edges));

    // ── Pass 2: measure every journey, then pack the blocks into columns ─────
    // Stacking journeys in one vertical ribbon made the board ~43000px tall and impossible
    // to scan. Measuring first lets each block drop into whichever column is currently
    // shortest, which keeps the whole HLD roughly square.
    const measured = [];
    for (const [name, gs] of journeys) {
      const rowHeights = [];
      for (let i = 0; i < gs.length; i += MAX_COLS) {
        rowHeights.push(Math.max(...gs.slice(i, i + MAX_COLS).map(s => columnHeight(s, navOf(s), extOf(s)))));
      }
      const cols = Math.min(gs.length, MAX_COLS);
      measured.push({
        name, scenes: gs, rowHeights,
        w: cols * CARD_W + (cols - 1) * CARD_GAP,
        h: rowHeights.reduce((a, b) => a + b, 0) + ROW_GAP * (rowHeights.length - 1),
      });
    }
    // Tallest first, so the big journeys anchor the columns and the small ones fill the gaps.
    measured.sort((a, b) => b.h - a.h);

    const colCount   = Math.max(1, Math.min(JOURNEY_COLS, measured.length));
    const colWidth   = MAX_COLS * CARD_W + (MAX_COLS - 1) * CARD_GAP + GROUP_PAD * 2 + GROUP_GAP;
    const colHeights = new Array(colCount).fill(0);

    const journeyBounds = [];        // { name, x, y, w, h }
    const sceneToGroup  = new Map(); // scene → its container frame

    // ── Pass 3: build one container per screen ──────────────────────────────
    // Card, stickies and API cloud used to sit on the page as 537 separate top-level
    // frames, and Figma draws every one of their names above them — that grey
    // "sticky:…" haze over the whole board. Nesting them leaves ~115 named nodes.
    for (const m of measured) {
      let c = 0;
      for (let i = 1; i < colCount; i++) if (colHeights[i] < colHeights[c]) c = i;

      const originX = c * colWidth + GROUP_PAD;
      const originY = colHeights[c] + GROUP_PAD + GROUP_LABEL_H;
      let rowTop = originY;

      for (let i = 0; i < m.scenes.length; i++) {
        const scene = m.scenes[i];
        const col = i % MAX_COLS;
        if (col === 0 && i > 0) rowTop += m.rowHeights[Math.floor(i / MAX_COLS) - 1] + ROW_GAP;

        const container = await buildScreenGroup(scene, navOf(scene), extOf(scene));
        container.x = originX + col * (CARD_W + CARD_GAP);
        container.y = rowTop;
        tag(container);
        figma.currentPage.appendChild(container);
        sceneToGroup.set(scene, container);
      }

      colHeights[c] = originY + m.h + GROUP_PAD + GROUP_GAP;
      journeyBounds.push({ name: m.name, x: originX, y: originY, w: m.w, h: m.h });
    }

    // ── Pass 4: labelled boundary behind each journey ────────────────────────
    for (const b of journeyBounds) {
      // insertChild(0, …) is the bottom of the z-order, so push the label in first
      // and the box after it — otherwise the box's fill covers its own title.
      const [box, label] = await buildJourneyBoundary(b);
      tag(box); tag(label);
      figma.currentPage.insertChild(0, label);
      figma.currentPage.insertChild(0, box);
    }

    // ── Pass 5: one arrow per screen-to-screen relationship ─────────────────
    let arrowCount = 0;
    for (const { from, to, count } of edges.values()) {
      if (from.group !== to.group) continue;
      const a = sceneToGroup.get(from), b = sceneToGroup.get(to);
      if (!a || !b) continue;
      const arrow = buildArrow(a, b, C.accent);
      if (!arrow) continue;
      arrow.name = count > 1 ? `${from.name} → ${to.name} (${count} actions)`
                             : `${from.name} → ${to.name}`;
      tag(arrow);
      figma.currentPage.appendChild(arrow);
      arrowCount++;
    }

    figma.viewport.scrollAndZoomIntoView([...sceneToGroup.values()]);
    figma.ui.postMessage({ type: 'done', detail: `${scenes.length} screens · ${journeys.size} journeys · ${arrowCount} arrows` });
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

// ── Destinations that are never a real screen-to-screen move ─────────────────
function shouldSkipDest(dest) {
  return !dest
    || dest.includes('next queued')
    || dest.includes('exits')
    || dest.includes('completes')
    || dest.includes('closes flow')
    || dest.includes('pops to root')
    // Parser artifacts: a bare navigation verb with no real destination behind it
    || /^(present|show|push|pop|dismiss):/.test(dest)
    || /^(back|self|nav)$/i.test(dest.trim());
}

/// Orders a journey's screens so every screen follows the ones that navigate into it
/// (Kahn's algorithm). Arrows then run forward instead of doubling back across the block.
/// Real navigation graphs contain cycles — a confirm screen returning to its input — so
/// whatever a cycle leaves unplaced is appended in its original order rather than dropped.
function flowOrder(sceneList, edges) {
  const inDegree = new Map(sceneList.map(s => [s, 0]));
  const out = new Map(sceneList.map(s => [s, []]));
  for (const { from, to } of edges.values()) {
    if (!inDegree.has(from) || !inDegree.has(to)) continue;   // different journey
    out.get(from).push(to);
    inDegree.set(to, inDegree.get(to) + 1);
  }

  const queue = sceneList.filter(s => inDegree.get(s) === 0);
  const ordered = [];
  while (queue.length) {
    const s = queue.shift();
    ordered.push(s);
    for (const next of out.get(s)) {
      inDegree.set(next, inDegree.get(next) - 1);
      if (inDegree.get(next) === 0) queue.push(next);
    }
  }
  for (const s of sceneList) if (!ordered.includes(s)) ordered.push(s);
  return ordered;
}

// ── One screen as a single node: card + stickies + API cloud ─────────────────
// Figma labels every top-level node, so leaving these loose put 537 names on the board.
async function buildScreenGroup(scene, nextNames, externalNames) {
  const group = figma.createFrame();
  group.name = `${scene.group} · ${scene.name}`;
  group.resize(CARD_W, columnHeight(scene, nextNames, externalNames));
  group.fills = noFill();
  group.clipsContent = false;

  const card = await buildScreenCard(scene, 0, 0);
  group.appendChild(card);

  let y = CARD_H + PANEL_GAP;

  const nav = await buildNavPanel(nextNames, externalNames);
  if (nav) { nav.y = y; group.appendChild(nav); y += nav.height + PANEL_GAP; }

  const api = await buildApiPanel(scene.apiEndpoints || []);
  if (api) { api.y = y; group.appendChild(api); }

  return group;
}

// ── "Goes to" panel ──────────────────────────────────────────────────────────
// An arrow already shows same-journey moves, but it does not name the ones that leave —
// another journey, or another module entirely — so those are listed here in text.
async function buildNavPanel(nextNames, externalNames) {
  const rows = [
    ...nextNames.map(n => ({ text: `→ ${n}`, color: C.accent })),
    ...externalNames.map(n => ({ text: `↗ ${n}`, color: C.amber })),
  ].slice(0, MAX_NAV_ROWS);
  if (rows.length === 0) return null;

  const f = figma.createFrame();
  f.name = 'goes to';
  f.resize(CARD_W, PANEL_HEAD_H + rows.length * ROW_H + PANEL_PAD);
  f.fills = solid(C.surface2, 0.7);
  f.strokes = solid(C.border);
  f.strokeWeight = 1;
  f.cornerRadius = 8;

  const head = figma.createText();
  head.fontName = { family: 'Inter', style: 'Semi Bold' };
  head.fontSize = 8;
  head.characters = 'GOES TO';
  head.letterSpacing = { unit: 'PIXELS', value: 0.6 };
  head.fills = solid(C.textDim);
  head.x = 10; head.y = 8;
  f.appendChild(head);

  rows.forEach((r, i) => {
    const t = figma.createText();
    t.fontName = { family: 'Inter', style: 'Regular' };
    t.fontSize = 9;
    t.characters = truncate(r.text, 44);
    t.fills = solid(r.color, 0.95);
    t.x = 10; t.y = PANEL_HEAD_H + i * ROW_H;
    f.appendChild(t);
  });

  return f;
}

// ── API panel: method, path, and the request/response models ─────────────────
async function buildApiPanel(endpoints) {
  if (endpoints.length === 0) return null;
  const shown = endpoints.slice(0, MAX_API_ROWS);

  const f = figma.createFrame();
  f.name = 'API';
  f.resize(CARD_W, PANEL_HEAD_H + shown.length * API_ROW_H + PANEL_PAD);
  f.fills = solid(C.green, 0.08);
  f.strokes = solid(C.green, 0.7);
  f.strokeWeight = 1;
  f.cornerRadius = 8;

  const head = figma.createText();
  head.fontName = { family: 'Inter', style: 'Semi Bold' };
  head.fontSize = 8;
  head.characters = 'API';
  head.letterSpacing = { unit: 'PIXELS', value: 0.6 };
  head.fills = solid(C.green);
  head.x = 10; head.y = 8;
  f.appendChild(head);

  shown.forEach((e, i) => {
    const top = PANEL_HEAD_H + i * API_ROW_H;

    const line = figma.createText();
    line.fontName = { family: 'Inter', style: 'Semi Bold' };
    line.fontSize = 9;
    line.characters = truncate(`${e.method || 'GET'}  ${e.path || ''}`, 46);
    line.fills = solid(C.green, 0.95);
    line.x = 10; line.y = top;
    f.appendChild(line);

    // Request/response model names come from BaseService<API, Request, Response>.
    if (e.requestType || e.responseType) {
      const models = figma.createText();
      models.fontName = { family: 'Inter', style: 'Regular' };
      models.fontSize = 8;
      models.characters = truncate(`req ${e.requestType || '—'}   resp ${e.responseType || '—'}`, 52);
      models.fills = solid(C.textDim);
      models.x = 10; models.y = top + 13;
      f.appendChild(models);
    }
  });

  return f;
}

// ── Which action chains earn a sticky ────────────────────────────────────────
function visibleActions(scene) {
  return (scene.actionChains || []).filter(a => {
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
}

/// Full vertical extent of one screen's column — card, its stack of stickies, and any API cloud.
/// Rows inside a journey are spaced by the tallest column, so a 76-sticky screen cannot overlap
/// the row beneath it.
function columnHeight(scene, nextNames, externalNames) {
  const navRows = Math.min((nextNames || []).length + (externalNames || []).length, MAX_NAV_ROWS);
  const apiRows = Math.min((scene.apiEndpoints || []).length, MAX_API_ROWS);
  let h = CARD_H;
  if (navRows > 0) h += PANEL_GAP + PANEL_HEAD_H + navRows * ROW_H + PANEL_PAD;
  if (apiRows > 0) h += PANEL_GAP + PANEL_HEAD_H + apiRows * API_ROW_H + PANEL_PAD;
  return h + PANEL_GAP;
}

/// Marks a node as this plugin's output so the next run can clear it without touching
/// anything the reader added to the page by hand.
function tag(node) { node.setPluginData('hldgen', '1'); }

// ── Journey boundary: dashed box + title, drawn behind its screens ────────────
async function buildJourneyBoundary(b) {
  const box = figma.createRectangle();
  box.name = `journey:${b.name}`;
  box.x = b.x - GROUP_PAD;
  box.y = b.y - GROUP_PAD;
  box.resize(b.w + GROUP_PAD * 2, b.h + GROUP_PAD * 2);
  box.fills = solid(C.surface, 0.35);
  box.strokes = solid(C.border);
  box.strokeWeight = 2;
  box.dashPattern = [10, 8];
  box.cornerRadius = 16;

  const label = figma.createText();
  label.fontName = { family: 'Inter', style: 'Semi Bold' };
  label.fontSize = 22;
  label.characters = b.name;
  label.fills = solid(C.textHead, 0.9);
  label.x = b.x - GROUP_PAD + 12;
  label.y = b.y - GROUP_PAD - GROUP_LABEL_H + 6;

  return [box, label];
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
