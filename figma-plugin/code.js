// NoNDesign Bridge — Figma 双向插件（2026-11-16）
// Import：读 nondesign.json（NoN 导出包）→ 逐板建真实可编辑 Figma Frame。
// Export：把当前页选区序列化成 NoNDesign 节点 JSON → 下载，供 NoN 物化。
// 纯手工节点映射，零网络。

figma.showUI(__html__, { width: 360, height: 420 });

figma.ui.onmessage = async (msg) => {
  if (msg.type === 'import') {
    const data = msg.data; // { boards: [{ id, name, width, height, nodes: [...] }] }
    const root = figma.currentPage;
    let made = 0;
    for (const b of data.boards || []) {
      const frame = figma.createFrame();
      frame.name = b.name || b.id;
      frame.x = 100 + (made % 4) * (b.width + 80);
      frame.y = 100 + Math.floor(made / 4) * (b.height + 80);
      frame.resize(b.width, b.height);
      frame.fills = [{ type: 'SOLID', color: hexToRgb(b.background || '#FFFFFF') }];
      for (const n of b.nodes || []) {
        if (n.style && n.style.visible === false) continue;
        const node = makeNode(n);
        if (node) { frame.appendChild(node); made2++; }
      }
      root.appendChild(frame);
      made++;
      figma.currentPage.selection = [frame];
      figma.viewport.scrollAndZoomIntoView([frame]);
    }
    var made2 = made2 || 0;
    figma.notify('NoNDesign: 导入完成 ' + made + ' 板');
    return;
  }
  if (msg.type === 'export-selection') {
    const sel = figma.currentPage.selection;
    const out = [];
    function walk(node, depth) {
      if (depth > 6) return;
      const item = {
        id: node.id,
        component: node.type === 'TEXT' ? 'body_text' : 'card',
        x: Math.round(node.x), y: Math.round(node.y),
        w: Math.round(node.width), h: Math.round(node.height),
        text: node.type === 'TEXT' ? node.characters : '',
        style: {
          fill: node.fills && node.fills[0] && node.fills[0].type === 'SOLID'
            ? rgbToHex(node.fills[0].color) : '#FFFFFF',
          text_color: node.type === 'TEXT' && node.fills[0] && node.fills[0].type === 'SOLID'
            ? rgbToHex(node.fills[0].color) : '#14161A',
          font_size: node.type === 'TEXT' ? Math.round(node.fontSize) : 14,
          radius: node.cornerRadius !== undefined && typeof node.cornerRadius === 'number'
            ? Math.round(node.cornerRadius) : 8,
          opacity: node.opacity !== undefined ? node.opacity : 1,
          visible: node.visible !== false,
        },
      };
      out.push(item);
      if ('children' in node) for (const c of node.children) walk(c, depth + 1);
    }
    const target = sel.length ? sel : figma.currentPage.children;
    for (const n of target) if ('width' in n) walk(n, 0);
    figma.ui.postMessage({ type: 'export-done', json: JSON.stringify({ boards: [{ id: 'imported', name: 'Figma 导入', width: 1440, height: 900, nodes: out }] }, null, 1) });
  }
};

let made2 = 0;

function makeNode(n) {
  const st = n.style || {};
  if ((n.text || '').trim() && (st.font_size || 14) !== 14 || n.component === 'body_text' || n.component === 'heading') {
    const t = figma.createText();
    t.characters = n.text || '';
    t.fontSize = st.font_size || 14;
    t.fills = [{ type: 'SOLID', color: hexToRgb(st.text_color || '#14161A') }];
    t.x = n.x; t.y = n.y;
    try { t.resize(n.w, n.h); } catch (e) {}
    return t;
  }
  const r = figma.createRectangle();
  r.resize(n.w, n.h);
  r.x = n.x; r.y = n.y;
  r.cornerRadius = Math.min(st.radius || 0, Math.min(n.w, n.h) / 2);
  r.fills = [{ type: 'SOLID', color: hexToRgb(st.fill && st.fill[0] !== '#' ? '#DDDDDD' : st.fill || '#FFFFFF') }];
  if (st.radius >= 999) r.cornerRadius = Math.min(n.w, n.h) / 2;
  return r;
}

function hexToRgb(hex) {
  hex = (hex || '#FFFFFF').replace('#', '');
  if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
  const n = parseInt(hex, 16) || 0;
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 };
}
function rgbToHex(c) {
  const h = (v) => Math.round(v * 255).toString(16).padStart(2, '0');
  return '#' + h(c.r) + h(c.g) + h(c.b);
}
