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
const API_ROW_H     = 42;   // endpoint line plus its request and response field lines
const MAX_NAV_ROWS  = 10;
const MAX_API_ROWS  = 6;
const MAX_LIST_ROWS = 6;
const HEADER_H      = 44;   // navigation title + view controller class, above the wireframe
const MAX_COLS       = 6;    // unlinked screens per row, under the flow
const LAYER_GAP      = 320;  // room between flow columns for a decision diamond and action labels
const BRANCH_STUB    = 14;   // short run out of a diamond before a branch turns toward its screen
const FANIN_SPACING  = 34;   // vertical gap between connectors entering the same screen
const STACK_GAP      = 60;   // vertical gap between screens in one flow column
const SECTION_GAP    = 120;  // between the flow and the unlinked-screen grid below it
const DECISION       = 44;
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
    const resolveDest = makeDestinationResolver(scenes);
    const edges = new Map();        // "srcName->dstName" → { from, to, count }
    // Every destination a screen reaches, resolved where possible. Rendered as clickable rows,
    // so a destination that is not drawn as a line is still one click away.
    const goesTo = new Map();       // scene → [{ label, target }]
    const addGoesTo = (s, label, target) => {
      if (!goesTo.has(s)) goesTo.set(s, []);
      const rows = goesTo.get(s);
      if (!rows.some(r => r.label === label)) rows.push({ label, target });
    };
    for (const s of scenes) {
      for (const chain of visibleActions(s)) {
        for (const dest of [...(chain.resolvedDestinations || []), ...(chain.vcRoutes || [])]) {
          if (shouldSkipDest(dest)) continue;
          const short = dest.replace('ViewController', 'VC').replace(' screen', '').trim();
          const t = resolveDest(dest, s);

          if (!t)                   { addGoesTo(s, `↗ ${short}`, null); continue; }
          if (t === s)              continue;                       // self-route, nothing to draw
          if (t.group !== s.group)  { addGoesTo(s, `↗ ${t.name} · ${t.group}`, t); continue; }
          addGoesTo(s, `→ ${t.name}`, t);

          const k = `${s.name}->${t.name}`;
          // Six buttons leading to the same screen is one relationship, not six arrows.
          if (!edges.has(k)) edges.set(k, { from: s, to: t, count: 0, actions: [] });
          const e = edges.get(k);
          e.count++;
          // Kept so each connector can say which action takes the user there.
          const act = (chain.action || '').replace(/^'|'$/g, '');
          if (act && !e.actions.includes(act)) e.actions.push(act);
        }
      }
    }

    // Same-journey destinations, named per screen for its "goes to" panel.
    const goesToOf = s => goesTo.get(s) || [];

    // ── Pass 2: lay out each journey as a left-to-right flow ────────────────
    // A grid put related screens anywhere and the arrows had to cross the block to reach
    // them. Layering by flow depth puts each screen one column after whatever leads into
    // it, so every line is a short hop between neighbouring columns.
    const layouts = [];
    for (const [name, gs] of journeys) {
      const layout = layoutJourney(gs, edges, s => columnHeight(s, goesToOf(s)));
      layouts.push({ name, ...layout });
    }
    // Tallest first, so the big journeys anchor the columns and the small ones fill the gaps.
    layouts.sort((x, y) => y.h - x.h);

    const colCount   = Math.max(1, Math.min(JOURNEY_COLS, layouts.length));
    const colWidth   = Math.max(...layouts.map(l => l.w)) + GROUP_PAD * 2 + GROUP_GAP;
    const colHeights = new Array(colCount).fill(0);

    const journeyBounds = [];
    const sceneToGroup  = new Map();
    let arrowCount = 0, decisionCount = 0;
    const linkRows = [];            // GOES TO rows to point at their screens once all exist

    for (const l of layouts) {
      let c = 0;
      for (let i = 1; i < colCount; i++) if (colHeights[i] < colHeights[c]) c = i;
      const ox = c * colWidth + GROUP_PAD;
      const oy = colHeights[c] + GROUP_PAD + GROUP_LABEL_H;

      // ── screens
      for (const [scene, p] of l.pos) {
        const container = await buildScreenGroup(scene, goesToOf(scene), linkRows);
        container.x = ox + p.x;
        container.y = oy + p.y;
        tag(container);
        figma.currentPage.appendChild(container);
        sceneToGroup.set(scene, container);
      }

      // ── connectors: straight hop for one next screen, a decision diamond for several
      const anchorOut = sc => { const p = l.pos.get(sc); return { x: ox + p.x + CARD_W, y: oy + p.y + HEADER_H + CARD_H / 2 }; };
      // Several connectors into one screen would share a single entry point and run along the
      // same horizontal line, stacking their lines and labels on top of each other. Each
      // incoming connector gets its own slot down the screen's left edge instead.
      const inbound = new Map();
      for (const [f, ts] of l.fwd) for (const t of ts) {
        if (!inbound.has(t)) inbound.set(t, []);
        inbound.get(t).push(f);
      }
      const anchorIn = (sc, from) => {
        const p = l.pos.get(sc);
        const srcs = inbound.get(sc) || [from];
        const i = Math.max(0, srcs.indexOf(from)), n = srcs.length;
        return { x: ox + p.x, y: oy + p.y + HEADER_H + CARD_H / 2 + (i - (n - 1) / 2) * FANIN_SPACING };
      };

      for (const [from, allTargets] of l.fwd) {
        // Only hops into the very next column are drawn. A line skipping columns has to run
        // through the screens in between; those destinations are reached from GOES TO instead.
        const col = l.pos.get(from).col;
        const targets = allTargets.filter(t => l.pos.get(t).col === col + 1);
        if (targets.length === 0) continue;
        const start = anchorOut(from);

        if (targets.length === 1) {
          const end = anchorIn(targets[0], from);
          const bend = end.x - LAYER_GAP / 2;
          const line = buildElbow(start, end, bend, C.accent);
          line.name = `${from.name} → ${targets[0].name}`;
          tag(line); figma.currentPage.appendChild(line); arrowCount++;
          await labelConnector(edges.get(`${from.name}->${targets[0].name}`), bend, end);
          continue;
        }

        const cx = start.x + LAYER_GAP / 2, cy = start.y;
        const diamond = await buildDecision(cx, cy, targets.length);
        diamond.name = `decision: ${from.name}`;
        tag(diamond); figma.currentPage.appendChild(diamond); decisionCount++;

        const into = buildElbow(start, { x: cx - DECISION / 2, y: cy }, start.x, C.accent);
        tag(into); figma.currentPage.appendChild(into); arrowCount++;

        for (const t of targets) {
          const end = anchorIn(t, from);
          // Bend right after the diamond so the final run into the screen is long enough to
          // carry the action name that picks this branch.
          const bend = cx + DECISION / 2 + BRANCH_STUB;
          const out = buildElbow({ x: cx + DECISION / 2, y: cy }, end, bend, C.accent);
          out.name = `${from.name} → ${t.name}`;
          tag(out); figma.currentPage.appendChild(out); arrowCount++;
          await labelConnector(edges.get(`${from.name}->${t.name}`), bend, end);
        }
      }

      colHeights[c] = oy + l.h + GROUP_PAD + GROUP_GAP;
      journeyBounds.push({ name: l.name, x: ox, y: oy, w: l.w, h: l.h });
    }

    // ── GOES TO rows become links to the screen they name ───────────────────
    let linkCount = 0;
    for (const { node, target } of linkRows) {
      const dest = sceneToGroup.get(target);
      if (!dest) continue;
      node.hyperlink = { type: 'NODE', value: dest.id };
      node.textDecoration = 'UNDERLINE';
      linkCount++;
    }

    // ── labelled boundary behind each journey ───────────────────────────────
    for (const bnd of journeyBounds) {
      // insertChild(0, …) is the bottom of the z-order, so push the label in first
      // and the box after it — otherwise the box's fill covers its own title.
      const [box, label] = await buildJourneyBoundary(bnd);
      tag(box); tag(label);
      figma.currentPage.insertChild(0, label);
      figma.currentPage.insertChild(0, box);
    }

    figma.viewport.scrollAndZoomIntoView([...sceneToGroup.values()]);
    figma.ui.postMessage({ type: 'done', detail: `${scenes.length} screens · ${journeys.size} journeys · ${decisionCount} decisions · ${arrowCount} lines · ${linkCount} links` });
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

/// Places one journey's screens in columns by flow depth.
///
/// Navigation graphs have cycles (a confirm screen returning to its input), so back-edges are
/// found by DFS and set aside first — the rest is acyclic and each screen's column is the longest
/// path leading into it. Screens with no same-journey links go in a grid under the flow, where
/// they no longer push connected screens apart. `heightOf` gives a screen's full column height.
function layoutJourney(sceneList, edges, heightOf) {
  const inJourney = new Set(sceneList);
  const out = new Map(sceneList.map(s => [s, []]));
  for (const { from, to } of edges.values()) {
    if (from !== to && inJourney.has(from) && inJourney.has(to) && !out.get(from).includes(to)) {
      out.get(from).push(to);
    }
  }

  const fwd  = new Map(sceneList.map(s => [s, []]));
  const back = new Map();
  const state = new Map();                         // 1 = on the DFS stack, 2 = finished
  const indeg = new Map(sceneList.map(s => [s, 0]));
  for (const ts of out.values()) for (const t of ts) indeg.set(t, indeg.get(t) + 1);
  const visit = s => {
    state.set(s, 1);
    for (const t of out.get(s)) {
      if (state.get(t) === 1) {                    // closes a loop
        if (!back.has(s)) back.set(s, []);
        back.get(s).push(t);
        continue;
      }
      fwd.get(s).push(t);
      if (!state.get(t)) visit(t);
    }
    state.set(s, 2);
  };
  // Entry screens first, so a loop is broken at its return edge rather than at its entry.
  for (const s of [...sceneList].sort((a, b) => indeg.get(a) - indeg.get(b))) {
    if (!state.get(s)) visit(s);
  }

  const layer = new Map(sceneList.map(s => [s, 0]));
  const fin = new Map(sceneList.map(s => [s, 0]));
  for (const ts of fwd.values()) for (const t of ts) fin.set(t, fin.get(t) + 1);
  const queue = sceneList.filter(s => fin.get(s) === 0);
  while (queue.length) {
    const s = queue.shift();
    for (const t of fwd.get(s)) {
      layer.set(t, Math.max(layer.get(t), layer.get(s) + 1));
      fin.set(t, fin.get(t) - 1);
      if (fin.get(t) === 0) queue.push(t);
    }
  }

  const linked = new Set();
  for (const [s, ts] of fwd) if (ts.length) { linked.add(s); ts.forEach(t => linked.add(t)); }

  const columns = [];
  for (const s of sceneList) {
    if (!linked.has(s)) continue;
    const L = layer.get(s);
    (columns[L] = columns[L] || []).push(s);
  }
  // Order each column by where its parents sit, which untangles most crossings.
  const rank = new Map();
  columns.forEach((col, L) => {
    if (L > 0) {
      const parentRank = s => {
        const ps = sceneList.filter(p => fwd.get(p).includes(s) && rank.has(p)).map(p => rank.get(p));
        return ps.length ? ps.reduce((a, b) => a + b, 0) / ps.length : 1e9;
      };
      col.sort((a, b) => parentRank(a) - parentRank(b));
    }
    col.forEach((s, i) => rank.set(s, i));
  });

  const pos = new Map();
  columns.forEach((col, L) => col.forEach(s => pos.set(s, { x: L * (CARD_W + LAYER_GAP), y: 0, h: heightOf(s), col: L })));
  const loose = sceneList.filter(s => !linked.has(s));
  loose.forEach((s, i) => pos.set(s, { x: (i % MAX_COLS) * (CARD_W + CARD_GAP), y: 0, h: heightOf(s), grid: i }));

  const layout = { pos, fwd, back, columns, loose, w: 0, h: 0 };
  restack(layout);
  return layout;
}

/// Recomputes y positions and block size from each screen's current height.
function restack(layout) {
  let flowBottom = 0;
  for (const col of layout.columns) {
    if (!col) continue;
    let y = 0;
    for (const s of col) { const p = layout.pos.get(s); p.y = y; y += p.h + STACK_GAP; }
    flowBottom = Math.max(flowBottom, y - STACK_GAP);
  }
  let y = layout.columns.length ? flowBottom + SECTION_GAP : 0, rowH = 0;
  layout.loose.forEach((s, i) => {
    const p = layout.pos.get(s);
    if (i > 0 && i % MAX_COLS === 0) { y += rowH + ROW_GAP; rowH = 0; }
    p.y = y; rowH = Math.max(rowH, p.h);
  });
  const bottom = layout.loose.length ? y + rowH : flowBottom;
  let w = 0;
  for (const p of layout.pos.values()) w = Math.max(w, p.x + CARD_W);
  layout.w = w;
  layout.h = Math.max(bottom, CARD_H);
}

/// Writes the triggering action(s) just above a connector's last horizontal run, so a branch
/// out of a decision reads as "this action → that screen" rather than an unexplained split.
async function labelConnector(edge, fromX, end) {
  if (!edge || !edge.actions || edge.actions.length === 0) return;
  const room = end.x - fromX - 12;
  const maxChars = Math.max(8, Math.floor(room / 5.4));
  const first = edge.actions[0];
  const more = edge.actions.length - 1;
  let text = more > 0 ? `${first} +${more}` : first;
  if (text.length > maxChars) text = truncate(first, maxChars - (more > 0 ? String(more).length + 2 : 0)) + (more > 0 ? ` +${more}` : '');

  const t = figma.createText();
  t.fontName = { family: 'Inter', style: 'Regular' };
  t.fontSize = 9;
  t.characters = text;
  t.fills = solid(C.text);
  t.x = fromX + 6;
  t.y = end.y - 15;
  t.name = `action: ${edge.actions.join(', ')}`;   // full list stays inspectable in Figma
  tag(t);
  figma.currentPage.appendChild(t);
}

/// Right-angled connector: out horizontally, down or up at `bendX`, in horizontally.
function buildElbow(a, b, bendX, color) {
  const pts = [a, { x: bendX, y: a.y }, { x: bendX, y: b.y }, b];
  const minX = Math.min(...pts.map(p => p.x)), minY = Math.min(...pts.map(p => p.y));
  const v = figma.createVector();
  v.x = minX; v.y = minY;
  v.fills = [];
  v.strokes = solid(color);
  v.strokeWeight = 2;
  v.vectorNetwork = {
    vertices: pts.map((p, i) => ({
      x: p.x - minX, y: p.y - minY,
      strokeCap: i === pts.length - 1 ? 'ARROW_LINES' : 'NONE',
      strokeJoin: 'ROUND', cornerRadius: 0, handleMirroring: 'NONE',
    })),
    segments: [{ start: 0, end: 1 }, { start: 1, end: 2 }, { start: 2, end: 3 }],
    regions: [],
  };
  return v;
}

/// Diamond marking a screen that can lead to more than one place.
async function buildDecision(cx, cy, branches) {
  const d = figma.createVector();
  d.x = cx - DECISION / 2; d.y = cy - DECISION / 2;
  d.vectorPaths = [{ windingRule: 'NONZERO',
    data: `M ${DECISION / 2} 0 L ${DECISION} ${DECISION / 2} L ${DECISION / 2} ${DECISION} L 0 ${DECISION / 2} Z` }];
  d.fills = solid(C.amber, 0.18);
  d.strokes = solid(C.amber);
  d.strokeWeight = 2;

  const t = figma.createText();
  t.fontName = { family: 'Inter', style: 'Semi Bold' };
  t.fontSize = 10;
  t.characters = `${branches}`;
  t.fills = solid(C.amber);
  t.x = cx - 4; t.y = cy - 7;

  const g = figma.group([d, t], figma.currentPage);
  return g;
}

// ── One screen as a single node: card + stickies + API cloud ─────────────────
// Figma labels every top-level node, so leaving these loose put 537 names on the board.
async function buildScreenGroup(scene, goesToRows, linkRows) {
  const group = figma.createFrame();
  group.name = `${scene.group} · ${scene.name}`;
  group.resize(CARD_W, columnHeight(scene, goesToRows));
  group.fills = noFill();
  group.clipsContent = false;

  group.appendChild(await buildScreenHeader(scene));

  const card = await buildScreenCard(scene, 0, HEADER_H);
  group.appendChild(card);

  let y = HEADER_H + CARD_H + PANEL_GAP;
  const place = panel => {
    if (!panel) return;
    panel.y = y;
    group.appendChild(panel);
    y += panel.height + PANEL_GAP;
  };

  place(await buildNavPanel(goesToRows, linkRows));
  place(await buildApiPanel(scene.apiEndpoints || []));
  place(await buildListPanel('NOTIFICATION CENTER',
    (scene.notifications || []).map(n => ({ text: n, color: C.pink })), C.pink));
  place(await buildListPanel('LOCAL STORAGE',
    (scene.localStorage || []).map(n => ({ text: n, color: C.text })), C.textDim));

  return group;
}

// ── Header: the title a user sees, then the class a developer searches for ────
async function buildScreenHeader(scene) {
  const f = figma.createFrame();
  f.name = 'header';
  f.resize(CARD_W, HEADER_H);
  f.fills = noFill();

  const title = figma.createText();
  title.fontName = { family: 'Inter', style: 'Semi Bold' };
  title.fontSize = 14;
  const hasTitle = !!scene.navigationTitle;
  title.characters = truncate(
    hasTitle ? scene.navigationTitle
             : scene.navigationBarHidden ? 'No navigation bar' : 'No navigation title found', 34);
  title.fills = hasTitle ? solid(C.textHead) : solid(C.textDim);
  title.x = 2; title.y = 2;
  f.appendChild(title);

  const vc = figma.createText();
  vc.fontName = { family: 'Inter', style: 'Regular' };
  vc.fontSize = 10;
  vc.characters = truncate((scene.viewControllers || [])[0] || scene.name, 44);
  vc.fills = solid(C.accent);
  vc.x = 2; vc.y = 24;
  f.appendChild(vc);

  return f;
}

// ── Generic titled list, used for notifications and storage ─────────────────
async function buildListPanel(label, items, accent) {
  const rows = items.slice(0, MAX_LIST_ROWS);
  if (rows.length === 0) return null;
  const extra = items.length - rows.length;

  const f = figma.createFrame();
  f.name = label.toLowerCase();
  f.resize(CARD_W, PANEL_HEAD_H + (rows.length + (extra > 0 ? 1 : 0)) * ROW_H + PANEL_PAD);
  f.fills = solid(accent, 0.07);
  f.strokes = solid(accent, 0.6);
  f.strokeWeight = 1;
  f.cornerRadius = 8;

  const head = figma.createText();
  head.fontName = { family: 'Inter', style: 'Semi Bold' };
  head.fontSize = 8;
  head.characters = label;
  head.letterSpacing = { unit: 'PIXELS', value: 0.6 };
  head.fills = solid(accent);
  head.x = 10; head.y = 8;
  f.appendChild(head);

  rows.forEach((r, i) => {
    const t = figma.createText();
    t.fontName = { family: 'Inter', style: 'Regular' };
    t.fontSize = 9;
    t.characters = truncate(r.text, 48);
    t.fills = solid(r.color, 0.95);
    t.x = 10; t.y = PANEL_HEAD_H + i * ROW_H;
    f.appendChild(t);
  });
  if (extra > 0) {
    const t = figma.createText();
    t.fontName = { family: 'Inter', style: 'Regular' };
    t.fontSize = 9;
    t.characters = `+${extra} more`;
    t.fills = solid(C.textDim);
    t.x = 10; t.y = PANEL_HEAD_H + rows.length * ROW_H;
    f.appendChild(t);
  }
  return f;
}

// ── "Goes to" panel ──────────────────────────────────────────────────────────
// An arrow already shows same-journey moves, but it does not name the ones that leave —
// another journey, or another module entirely — so those are listed here in text.
async function buildNavPanel(goesToRows, linkRows) {
  const all = goesToRows || [];
  const rows = all.slice(0, MAX_NAV_ROWS);
  if (rows.length === 0) return null;
  const extra = all.length - rows.length;

  const f = figma.createFrame();
  f.name = 'goes to';
  f.resize(CARD_W, PANEL_HEAD_H + (rows.length + (extra > 0 ? 1 : 0)) * ROW_H + PANEL_PAD);
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
    t.characters = truncate(r.label, 44);
    // Blue: a screen on this board, linked. Amber: somewhere the board does not contain.
    t.fills = solid(r.target ? C.accent : C.amber, 0.95);
    t.x = 10; t.y = PANEL_HEAD_H + i * ROW_H;
    f.appendChild(t);
    if (r.target) linkRows.push({ node: t, target: r.target });
  });
  if (extra > 0) {
    const t = figma.createText();
    t.fontName = { family: 'Inter', style: 'Regular' };
    t.fontSize = 9;
    t.characters = `+${extra} more`;
    t.fills = solid(C.textDim);
    t.x = 10; t.y = PANEL_HEAD_H + rows.length * ROW_H;
    f.appendChild(t);
  }
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
    const method = e.method || 'GET';
    line.characters = `${method}  ${truncatePath(e.path || '', 46 - method.length - 2)}`;
    line.fills = solid(C.green, 0.95);
    line.x = 10; line.y = top;
    f.appendChild(line);

    // Field names come from the request/response models the service declares, so the panel
    // shows the actual payload instead of a type name nobody can look up from the board.
    const payload = [
      { label: 'req ', fields: e.requestFields,  fallback: e.requestType },
      { label: 'resp', fields: e.responseFields, fallback: e.responseType },
    ];
    payload.forEach((p, j) => {
      const names = (p.fields || []).map(f => f.json);
      const text = names.length ? names.join(', ') : (p.fallback || '—');
      const t = figma.createText();
      t.fontName = { family: 'Inter', style: 'Regular' };
      t.fontSize = 8;
      t.characters = `${p.label}  ${truncate(text, 50)}`;
      t.fills = solid(C.textDim);
      t.x = 16; t.y = top + 13 + j * 11;
      f.appendChild(t);
    });
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
function columnHeight(scene, goesToRows) {
  const listH = n => {
    if (n === 0) return 0;
    const rows = Math.min(n, MAX_LIST_ROWS) + (n > MAX_LIST_ROWS ? 1 : 0);
    return PANEL_GAP + PANEL_HEAD_H + rows * ROW_H + PANEL_PAD;
  };
  const nav = (goesToRows || []).length;
  const navRows = Math.min(nav, MAX_NAV_ROWS) + (nav > MAX_NAV_ROWS ? 1 : 0);
  const apiRows = Math.min((scene.apiEndpoints || []).length, MAX_API_ROWS);
  let h = HEADER_H + CARD_H;
  if (navRows > 0) h += PANEL_GAP + PANEL_HEAD_H + navRows * ROW_H + PANEL_PAD;
  if (apiRows > 0) h += PANEL_GAP + PANEL_HEAD_H + apiRows * API_ROW_H + PANEL_PAD;
  h += listH((scene.notifications || []).length);
  h += listH((scene.localStorage || []).length);
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

// ── Destination → screen ─────────────────────────────────────────────────────
/// Maps a destination string ("FeeDetail", "PTPPlayCardMainViewController screen", …) to the
/// screen it names. Destinations are usually flow-case names, not class names, so matching has to
/// be approximate — but the old matcher accepted any shared word, sending PlayCard's "FeeDetail"
/// to AddMoney's BankAddMoneyDetails and marking it a cross-journey hop, which is never drawn.
///
/// Candidates are scored instead: exact name > suffix > containment, only when the two names are
/// of comparable length, with a bonus for the source's own journey. Below the bar the destination
/// stays unresolved and shows as text — a missing line beats a line to the wrong screen.
function makeDestinationResolver(scenes) {
  const norm = x => x.toLowerCase().replace(/viewcontroller|screen/g, '').replace(/[^a-z0-9]/g, '');
  const PREFIX = /^(ptpplaycard|ptpplus|ptp|playcard|paotangpay)/;
  const keys = new Map(scenes.map(s => {
    const k = new Set([norm(s.name)]);
    for (const v of s.viewControllers || []) { const n = norm(v); k.add(n); k.add(n.replace(PREFIX, '')); }
    return [s, [...k].filter(Boolean)];
  }));
  const byClass = [];
  for (const s of scenes) for (const v of s.viewControllers || []) byClass.push([v, s]);

  return (dest, from) => {
    for (const [v, s] of byClass) if (dest.includes(v)) return s;
    const dn = norm(dest);
    if (dn.length < 3) return null;

    let best = null, bestScore = 0, bestGap = Infinity;
    for (const s of scenes) {
      let score = 0, gap = Infinity;
      for (const k of keys.get(s)) {
        const ratio = Math.min(k.length, dn.length) / Math.max(k.length, dn.length);
        const sameJourney = from && s.group === from.group;
        // Short destinations such as "Confirm", "Slip" or "Atm" are named relative to the
        // journey they sit in — ViaCasa → Confirm means ViaCasaConfirm, not PlayCard's Confirm —
        // so a prefix or suffix hit inside the source's journey outranks an exact hit elsewhere.
        const v = sameJourney && dn.length >= 3 && (k.endsWith(dn) || k.startsWith(dn)) && k !== dn ? 90
          : k === dn ? 100
          : ratio >= 0.6 && (k.endsWith(dn) || dn.endsWith(k)) ? 60
          : ratio >= 0.5 && (k.includes(dn) || dn.includes(k)) ? 40
          : 0;
        const g = Math.abs(k.length - dn.length);
        if (v > score || (v === score && v > 0 && g < gap)) { score = v; gap = g; }
      }
      if (!score) continue;
      if (from && s.group === from.group) score += 15;
      if (score > bestScore || (score === bestScore && gap < bestGap)) { best = s; bestScore = score; bestGap = gap; }
    }
    return bestScore >= 40 ? best : null;
  };
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

/// Shortens a path from the front, whole segments at a time: the tail names what the endpoint
/// does (`…/pocket/create`), while the shared prefix (`/paotang/v1/bff-…`) is the same on every row.
function truncatePath(path, max) {
  if (path.length <= max) return path;
  const parts = path.split('/').filter(Boolean);
  let tail = '';
  for (let i = parts.length - 1; i >= 0; i--) {
    const next = '/' + parts[i] + tail;
    if (('…' + next).length > max) break;
    tail = next;
  }
  // A single final segment longer than the room: keep its end rather than showing nothing.
  return tail ? '…' + tail : '…' + path.slice(path.length - (max - 1));
}

function truncate(str, max) {
  return str.length > max ? str.slice(0, max - 1) + '…' : str;
}
