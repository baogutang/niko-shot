/* Accessible theme, functional local-image capture lab, native gallery and release discovery. */
(() => {
  "use strict";
  const root = document.documentElement;
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const systemTheme = matchMedia("(prefers-color-scheme: dark)");
  const themeButton = document.querySelector(".theme-toggle");
  let explicitTheme = null;
  try { explicitTheme = localStorage.getItem("niko-shot-appearance"); } catch { /* Storage is optional. */ }
  if (explicitTheme === "light" || explicitTheme === "dark") root.dataset.theme = explicitTheme;
  const isDark = () => root.dataset.theme ? root.dataset.theme === "dark" : systemTheme.matches;
  const updateThemeButton = () => {
    if (!themeButton) return;
    const current = root.dataset.theme || "system";
    const names = { system: "系统", light: "浅色", dark: "深色" };
    const next = { system: "浅色", light: "深色", dark: "跟随系统" };
    const label = `外观：${names[current]}。点击切换${next[current]}。`;
    themeButton.setAttribute("aria-label", label);
    themeButton.title = label;
    themeButton.querySelector("use").setAttribute("href", `assets/icons.svg#${isDark() ? "moon" : "sun"}`);
    const themeLabel = themeButton.querySelector(".theme-label");
    if (themeLabel) themeLabel.textContent = names[current];
  };
  const previewImages = {
    ocr: { alt: "当前原生 OCR 窗口，左侧编辑文字，右侧并排核对原文和译文", width: 2240, height: 1360 },
    settings: { alt: "当前原生翻译设置，五类服务及独立的凭据配置区", width: 1800, height: 1300 },
    recording: { alt: "当前原生录屏配置，包含区域、画质、声音与摄像头选项", width: 1000, height: 1120 },
    scroll: { alt: "当前原生跟随长截图控制条：自行滚动、自动拼接，完成后编辑；高级操作按需展开", width: 768, height: 196 }
  };
  let preview = "ocr";
  const nativeImage = document.querySelector("#native-image");
  const updatePreview = () => {
    if (!nativeImage) return;
    nativeImage.src = `assets/app-${preview}${isDark() ? "-dark" : ""}.png`;
    const stem = `assets/app-${preview}${isDark() ? "-dark" : ""}`;
    nativeImage.srcset = `${stem}-compact.png ${previewImages[preview].width / 2}w, ${stem}.png ${previewImages[preview].width}w`;
    nativeImage.sizes = "(max-width: 720px) calc(100vw - 60px), (max-width: 980px) calc(100vw - 108px), 1080px";
    nativeImage.alt = previewImages[preview].alt;
    nativeImage.classList.toggle("scroll-preview", preview === "scroll");
    nativeImage.width = previewImages[preview].width;
    nativeImage.height = previewImages[preview].height;
  };
  themeButton?.addEventListener("click", () => {
    const next = { system: "light", light: "dark", dark: "system" }[root.dataset.theme || "system"];
    if (next === "system") delete root.dataset.theme;
    else root.dataset.theme = next;
    try {
      if (next === "system") localStorage.removeItem("niko-shot-appearance");
      else localStorage.setItem("niko-shot-appearance", next);
    } catch { /* Theme still works without persistent storage. */ }
    updateThemeButton(); updatePreview();
  });
  systemTheme.addEventListener("change", () => { updateThemeButton(); updatePreview(); });
  updateThemeButton(); updatePreview();
  const tabs = [...document.querySelectorAll("[data-preview]")];
  const selectPreview = (tab) => {
    preview = tab.dataset.preview;
    tabs.forEach(item => { item.setAttribute("aria-selected", String(item === tab)); item.tabIndex = item === tab ? 0 : -1; });
    document.querySelector("#native-preview").setAttribute("aria-labelledby", tab.id);
    updatePreview();
  };
  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => selectPreview(tab));
    tab.addEventListener("keydown", event => {
      let next;
      if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
      if (event.key === "ArrowLeft") next = (index + tabs.length - 1) % tabs.length;
      if (event.key === "Home") next = 0;
      if (event.key === "End") next = tabs.length - 1;
      if (next === undefined) return;
      event.preventDefault(); selectPreview(tabs[next]); tabs[next].focus();
    });
  });
  document.querySelectorAll("[data-show-preview]").forEach(link => {
    link.addEventListener("click", () => {
      const tab = tabs.find(item => item.dataset.preview === link.dataset.showPreview);
      if (tab) selectPreview(tab);
    });
  });
  const navigationButton = document.querySelector(".nav-toggle");
  const siteHeader = document.querySelector(".site-header");
  if (navigationButton && siteHeader) {
    navigationButton.hidden = false;
    const setNavigationOpen = open => {
      siteHeader.dataset.menuOpen = String(open);
      navigationButton.setAttribute("aria-expanded", String(open));
      navigationButton.setAttribute("aria-label", open ? "收起导航" : "展开导航");
      navigationButton.querySelector("use").setAttribute("href", `assets/icons.svg#${open ? "x" : "menu-2"}`);
    };
    navigationButton.addEventListener("click", () => setNavigationOpen(navigationButton.getAttribute("aria-expanded") !== "true"));
    siteHeader.querySelectorAll(".nav-links a").forEach(link => link.addEventListener("click", () => setNavigationOpen(false)));
    siteHeader.addEventListener("keydown", event => {
      if (event.key === "Escape" && navigationButton.getAttribute("aria-expanded") === "true") {
        event.preventDefault(); setNavigationOpen(false); navigationButton.focus();
      }
    });
  }
  const guideLinks = [...document.querySelectorAll(".guide-nav a")];
  if (guideLinks.length) {
    const updateGuideLocation = () => guideLinks.forEach(link => {
      if (link.hash === (location.hash || guideLinks[0].hash)) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    });
    updateGuideLocation();
    window.addEventListener("hashchange", updateGuideLocation);
  }
  // Progressive enhancement: no observer or JS still leaves all text and imagery visible.
  if ("IntersectionObserver" in window && !reducedMotion.matches) {
    root.classList.add("js-ready");
    const reveal = new IntersectionObserver(entries => {
      for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add("is-visible"); reveal.unobserve(entry.target); }
    }, { threshold: .08 });
    document.querySelectorAll(".reveal").forEach(element => reveal.observe(element));
    reducedMotion.addEventListener("change", () => { if (reducedMotion.matches) { reveal.disconnect(); root.classList.remove("js-ready"); } });
    window.addEventListener("pagehide", () => reveal.disconnect(), { once: true });
  }

  const releaseStatus = document.querySelector("#release-status");
  if (releaseStatus) {
    const navigationURL = "https://github.com/baogutang/niko-shot/releases/tag/nightly";
    const architectureNames = { arm64: "M 芯片", x86_64: "Intel" };
    const architectureInputs = [...document.querySelectorAll('input[name="download-architecture"]')];
    const selectedChip = document.querySelector("#selected-chip");
    let selectedArchitecture = "arm64";
    let candidateDestinations = null;
    const updateDownloadSelection = () => {
      const label = architectureNames[selectedArchitecture];
      if (selectedChip) selectedChip.textContent = `已选：${label} · ${selectedArchitecture}。可在苹果菜单「关于本机」查看芯片或处理器。`;
      for (const kind of ["dmg", "zip"]) {
        const anchor = document.querySelector(`[data-download="${kind}"]`);
        if (!anchor) continue;
        anchor.href = candidateDestinations?.[selectedArchitecture][kind] || navigationURL;
        anchor.setAttribute("aria-label", candidateDestinations
          ? `下载 ${label} 版 ${kind.toUpperCase()} 安装包`
          : `前往 GitHub 候选页查看 ${label} 版 ${kind.toUpperCase()} 安装包`);
        const text = anchor.querySelector("[data-download-label]");
        if (text) text.textContent = `${label} · ${kind.toUpperCase()}`;
      }
    };
    architectureInputs.forEach(input => {
      input.checked = input.value === selectedArchitecture;
      input.addEventListener("change", () => {
        if (!input.checked || !Object.hasOwn(architectureNames, input.value)) return;
        selectedArchitecture = input.value;
        updateDownloadSelection();
      });
    });
    for (const selector of ["#chip-selector", "#selected-chip", "#download-actions"]) {
      const element = document.querySelector(selector);
      if (element) element.hidden = false;
    }
    updateDownloadSelection();
    releaseStatus.textContent = "正在核对同一候选的两种芯片安装包…";
    const releaseController = new AbortController();
    const timeout = setTimeout(() => releaseController.abort(), 8000);
    fetch("https://api.github.com/repos/baogutang/niko-shot/releases/tags/nightly", {
      headers: { Accept: "application/vnd.github+json" }, signal: releaseController.signal
    }).then(response => {
      if (!response.ok) throw new Error("release_unavailable");
      return response.json();
    }).then(async navigation => {
      const marker = typeof navigation.body === "string" ? navigation.body.match(/<!-- niko-shot-candidate: (candidate-\d+-\d+-[0-9a-f]{12}) -->/) : null;
      if (!marker) throw new Error("candidate_unavailable");
      const tag = marker[1];
      const response = await fetch(`https://api.github.com/repos/baogutang/niko-shot/releases/tags/${tag}`, {
        headers: { Accept: "application/vnd.github+json" }, signal: releaseController.signal
      });
      if (!response.ok) throw new Error("candidate_unavailable");
      const release = await response.json();
      if (release.tag_name !== tag || release.draft) throw new Error("candidate_unavailable");
      const assets = Array.isArray(release.assets) ? release.assets : [];
      const filenames = [
        "niko-shot-arm64.dmg", "niko-shot-arm64.zip", "niko-shot-x86_64.dmg", "niko-shot-x86_64.zip",
        "release-info-arm64.json", "release-info-x86_64.json", "release-info.json", "SHA256SUMS"
      ];
      const destinations = {};
      for (const name of filenames) {
        const matches = assets.filter(item => item.name === name);
        const asset = matches[0];
        if (matches.length !== 1 || !asset || asset.state !== "uploaded"
          || !Number.isSafeInteger(asset.size) || asset.size <= 0
          || typeof asset.browser_download_url !== "string") throw new Error("assets_unavailable");
        const url = new URL(asset.browser_download_url);
        if (url.origin !== "https://github.com" || url.username || url.password
          || url.pathname !== `/baogutang/niko-shot/releases/download/${tag}/${name}`
          || url.search || url.hash) throw new Error("assets_unavailable");
        destinations[name] = url.href;
      }
      // No download is enabled until both architectures and all provenance files belong to this candidate.
      candidateDestinations = Object.freeze(Object.fromEntries(Object.keys(architectureNames).map(architecture => [
        architecture, Object.freeze({
          dmg: destinations[`niko-shot-${architecture}.dmg`], zip: destinations[`niko-shot-${architecture}.zip`]
        })
      ])));
      document.querySelector('[data-download="checksums"]').href = destinations.SHA256SUMS;
      document.querySelector('[data-download="manifest"]').href = destinations["release-info.json"];
      updateDownloadSelection();
      const published = release.published_at ? new Date(release.published_at) : null;
      const date = published && !Number.isNaN(published.getTime()) ? published.toLocaleDateString("zh-CN", { year: "numeric", month: "long", day: "numeric" }) : "";
      releaseStatus.textContent = `两种芯片安装包均已就绪${date ? ` · ${date}` : ""}，来自同一 GitHub 候选。`;
    }).catch(() => {
      releaseStatus.textContent = "暂时无法核对两种芯片的完整候选。安装包按钮会带你前往 GitHub 产物页。";
    }).finally(() => clearTimeout(timeout));
    window.addEventListener("pagehide", () => { clearTimeout(timeout); releaseController.abort(); }, { once: true });
  }

  const canvas = document.querySelector("#capture-canvas");
  if (!canvas) return;
  const context = canvas.getContext("2d");
  if (!context) return;
  const status = document.querySelector("#demo-status");
  const sizeLabel = document.querySelector("#selection-size");
  const lab = document.querySelector(".capture-lab");
  const undoButton = document.querySelector("#undo-demo");
  const playButton = document.querySelector("#play-demo");
  const source = new Image();
  const defaultSelection = () => ({ x: .08, y: .085, w: .84, h: .8 });
  let selection = defaultSelection();
  let tool = "crop";
  let annotations = [];
  let currentStroke = null;
  let pointerStart = null;
  let keyboardStart = null;
  let keyboardPoint = { x: .5, y: .48 };
  let frame = 0;
  let demoTimers = [];
  let playing = false;
  const clamp = (value, min = 0, max = 1) => Math.min(max, Math.max(min, value));
  const announce = message => { status.textContent = message; };
  const requestDraw = () => { if (!frame) frame = requestAnimationFrame(() => { frame = 0; draw(); }); };
  const stopDemo = () => {
    demoTimers.forEach(clearTimeout); demoTimers = []; playing = false; lab.classList.remove("is-playing");
    playButton.querySelector("span").textContent = "播放演示";
    playButton.querySelector("use").setAttribute("href", "assets/icons.svg#player-play");
  };
  const drawStroke = (ctx, stroke, width, height) => {
    if (!stroke || !stroke.points.length) return;
    const first = stroke.points[0]; const last = stroke.points[stroke.points.length - 1];
    ctx.strokeStyle = "#b8790f"; ctx.lineWidth = Math.max(3, width * .004); ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.beginPath();
    if (stroke.tool === "rectangle") ctx.rect(first.x * width, first.y * height, (last.x - first.x) * width, (last.y - first.y) * height);
    else { ctx.moveTo(first.x * width, first.y * height); stroke.points.slice(1).forEach(point => ctx.lineTo(point.x * width, point.y * height)); }
    ctx.stroke();
    if (stroke.tool === "arrow" && stroke.points.length > 1) {
      const angle = Math.atan2((last.y - first.y) * height, (last.x - first.x) * width);
      const head = Math.max(14, width * .018);
      ctx.beginPath(); ctx.moveTo(last.x * width - head * Math.cos(angle - Math.PI / 6), last.y * height - head * Math.sin(angle - Math.PI / 6));
      ctx.lineTo(last.x * width, last.y * height);
      ctx.lineTo(last.x * width - head * Math.cos(angle + Math.PI / 6), last.y * height - head * Math.sin(angle + Math.PI / 6)); ctx.stroke();
    }
  };
  function draw() {
    if (!source.complete || !source.naturalWidth) return;
    const width = canvas.width; const height = canvas.height;
    context.clearRect(0, 0, width, height); context.drawImage(source, 0, 0, width, height);
    const { x, y, w, h } = selection;
    context.fillStyle = "rgba(22,20,17,.48)";
    context.fillRect(0, 0, width, y * height); context.fillRect(0, (y + h) * height, width, (1 - y - h) * height);
    context.fillRect(0, y * height, x * width, h * height); context.fillRect((x + w) * width, y * height, (1 - x - w) * width, h * height);
    annotations.forEach(stroke => drawStroke(context, stroke, width, height)); drawStroke(context, currentStroke, width, height);
    context.strokeStyle = "#e8a333"; context.lineWidth = 2; context.strokeRect(x * width, y * height, w * width, h * height);
    context.fillStyle = "#f9d999";
    [[x,y],[x+w,y],[x,y+h],[x+w,y+h]].forEach(([cx,cy]) => context.fillRect(cx * width - 4, cy * height - 4, 8, 8));
    if (document.activeElement === canvas && tool !== "crop") {
      context.strokeStyle = "#332b1d"; context.lineWidth = 1.5; const cx = keyboardPoint.x * width; const cy = keyboardPoint.y * height;
      context.beginPath(); context.moveTo(cx - 9, cy); context.lineTo(cx + 9, cy); context.moveTo(cx, cy - 9); context.lineTo(cx, cy + 9); context.stroke();
    }
    sizeLabel.textContent = `${Math.round(w * source.naturalWidth)} × ${Math.round(h * source.naturalHeight)} px`;
    undoButton.disabled = !annotations.length;
  }
  const setTool = (next, focus = true) => {
    tool = next; currentStroke = null; keyboardStart = null;
    document.querySelectorAll("[data-tool]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.tool === tool)));
    const names = { crop: "框选", arrow: "箭头", rectangle: "矩形", pencil: "画笔" };
    announce(tool === "crop" ? "拖动框选，方向键微调，Enter 确认。" : `已选择${names[tool]}。拖动绘制；键盘可用空格开始、方向键移动、空格完成。`);
    if (focus) canvas.focus({ preventScroll: true }); requestDraw();
  };
  document.querySelectorAll("[data-tool]").forEach(button => button.addEventListener("click", () => { stopDemo(); setTool(button.dataset.tool); }));
  const pointFor = event => {
    const rect = canvas.getBoundingClientRect();
    return { x: clamp((event.clientX - rect.left) / rect.width), y: clamp((event.clientY - rect.top) / rect.height) };
  };
  const normalizedBox = (a, b) => {
    const x = clamp(Math.min(a.x, b.x), 0, .98); const y = clamp(Math.min(a.y, b.y), 0, .98);
    return { x, y, w: Math.min(1 - x, Math.max(.02, Math.abs(a.x - b.x))), h: Math.min(1 - y, Math.max(.02, Math.abs(a.y - b.y))) };
  };
  canvas.addEventListener("pointerdown", event => {
    if (!source.naturalWidth || (event.pointerType === "mouse" && event.button !== 0)) return;
    stopDemo(); canvas.focus({ preventScroll: true }); canvas.setPointerCapture(event.pointerId);
    pointerStart = pointFor(event); keyboardPoint = pointerStart; keyboardStart = null;
    if (tool !== "crop") currentStroke = { tool, points: [pointerStart, pointerStart] };
    requestDraw();
  });
  canvas.addEventListener("pointermove", event => {
    if (!pointerStart) return;
    const point = pointFor(event); keyboardPoint = point;
    if (tool === "crop") selection = normalizedBox(pointerStart, point);
    else if (tool === "pencil") { if (currentStroke.points.length < 2000) currentStroke.points.push(point); }
    else currentStroke.points[1] = point;
    requestDraw();
  });
  const finishPointer = event => {
    if (!pointerStart) return;
    if (currentStroke) { annotations.push(currentStroke); if (annotations.length > 64) annotations.shift(); currentStroke = null; }
    pointerStart = null;
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
    announce(`已更新${tool === "crop" ? "选区" : "标注"}，可继续编辑或导出 PNG。`); requestDraw();
  };
  canvas.addEventListener("pointerup", finishPointer);
  canvas.addEventListener("pointercancel", () => { pointerStart = null; currentStroke = null; requestDraw(); });
  canvas.addEventListener("focus", requestDraw); canvas.addEventListener("blur", requestDraw);
  canvas.addEventListener("keydown", event => {
    if (!source.naturalWidth) return;
    const shortcuts = { c: "crop", a: "arrow", r: "rectangle", p: "pencil" };
    if (!event.metaKey && !event.ctrlKey && shortcuts[event.key.toLowerCase()]) { event.preventDefault(); stopDemo(); setTool(shortcuts[event.key.toLowerCase()]); return; }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") { event.preventDefault(); stopDemo(); annotations.pop(); announce("已撤销最后一个标注。"); requestDraw(); return; }
    if (event.key === "Escape") { event.preventDefault(); stopDemo(); selection = defaultSelection(); annotations = []; currentStroke = null; keyboardStart = null; setTool("crop"); return; }
    if (event.key === "Enter") { event.preventDefault(); stopDemo(); announce(`选区已确认：${sizeLabel.textContent}。可复制或导出 PNG。`); requestDraw(); return; }
    if (event.code === "Space" && tool !== "crop") {
      event.preventDefault(); stopDemo();
      if (!keyboardStart) { keyboardStart = { ...keyboardPoint }; currentStroke = { tool, points: [{ ...keyboardPoint }, { ...keyboardPoint }] }; announce("开始绘制，方向键移动，空格完成。"); }
      else { annotations.push(currentStroke); if (annotations.length > 64) annotations.shift(); currentStroke = null; keyboardStart = null; announce("标注已完成。"); }
      requestDraw(); return;
    }
    const vectors = { ArrowLeft: [-1,0], ArrowRight: [1,0], ArrowUp: [0,-1], ArrowDown: [0,1] };
    const vector = vectors[event.key]; if (!vector) return;
    event.preventDefault(); stopDemo(); const pixels = event.shiftKey ? 10 : 1;
    const dx = vector[0] * pixels / source.naturalWidth; const dy = vector[1] * pixels / source.naturalHeight;
    if (tool === "crop") { selection.x = clamp(selection.x + dx, 0, 1 - selection.w); selection.y = clamp(selection.y + dy, 0, 1 - selection.h); }
    else {
      keyboardPoint.x = clamp(keyboardPoint.x + dx); keyboardPoint.y = clamp(keyboardPoint.y + dy);
      if (currentStroke) { if (tool === "pencil") { if (currentStroke.points.length < 2000) currentStroke.points.push({ ...keyboardPoint }); } else currentStroke.points[1] = { ...keyboardPoint }; }
    }
    requestDraw();
  });
  undoButton.addEventListener("click", () => { stopDemo(); annotations.pop(); announce("已撤销最后一个标注。"); requestDraw(); });
  const createExport = () => new Promise((resolve, reject) => {
    if (!source.naturalWidth) { reject(new Error("图片尚未载入。")); return; }
    const output = document.createElement("canvas");
    output.width = Math.max(1, Math.round(selection.w * source.naturalWidth)); output.height = Math.max(1, Math.round(selection.h * source.naturalHeight));
    const ctx = output.getContext("2d"); if (!ctx) { reject(new Error("此浏览器无法创建图像。")); return; }
    ctx.drawImage(source, selection.x * source.naturalWidth, selection.y * source.naturalHeight, selection.w * source.naturalWidth, selection.h * source.naturalHeight, 0, 0, output.width, output.height);
    ctx.save(); ctx.translate(-selection.x * source.naturalWidth, -selection.y * source.naturalHeight);
    annotations.forEach(stroke => drawStroke(ctx, stroke, source.naturalWidth, source.naturalHeight)); ctx.restore();
    output.toBlob(blob => blob ? resolve(blob) : reject(new Error("导出失败，请重试。")), "image/png");
  });
  document.querySelector("#export-demo").addEventListener("click", async event => {
    stopDemo(); const button = event.currentTarget; button.disabled = true;
    try { const blob = await createExport(); const url = URL.createObjectURL(blob); const anchor = document.createElement("a"); anchor.href = url; anchor.download = "niko-shot-demo.png"; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); announce("PNG 已导出，包含选区内的标注。"); }
    catch (error) { announce(error.message || "导出失败，请重试。"); }
    finally { button.disabled = false; }
  });
  document.querySelector("#copy-demo").addEventListener("click", async event => {
    stopDemo(); const button = event.currentTarget;
    if (!navigator.clipboard?.write || !window.ClipboardItem) { announce("当前浏览器不支持图片复制，请使用导出 PNG。"); return; }
    button.disabled = true;
    try { await navigator.clipboard.write([new ClipboardItem({ "image/png": createExport() })]); announce("选中的图片已复制。"); }
    catch { announce("图片复制未获浏览器允许，请使用导出 PNG。"); }
    finally { button.disabled = false; }
  });
  playButton.addEventListener("click", () => {
    if (playing) { stopDemo(); announce("演示已暂停，可以自行编辑。"); return; }
    if (!source.naturalWidth) return;
    selection = defaultSelection(); annotations = []; currentStroke = null; setTool("crop", false);
    const arrow = { tool: "arrow", points: [{x:.67,y:.48},{x:.43,y:.48}] };
    if (reducedMotion.matches) { annotations.push(arrow); announce("减少动态效果已开启，直接展示框选与箭头标注结果。"); requestDraw(); return; }
    playing = true; lab.classList.add("is-playing"); playButton.querySelector("span").textContent = "暂停演示"; playButton.querySelector("use").setAttribute("href", "assets/icons.svg#player-pause");
    announce("演示：冻结图像并框选区域。"); requestDraw();
    demoTimers.push(setTimeout(() => { annotations.push(arrow); announce("演示：添加箭头，让重点一目了然。"); requestDraw(); }, 1300));
    demoTimers.push(setTimeout(() => { stopDemo(); announce("演示完成。现在可以自行框选、标注和导出。"); requestDraw(); }, 3000));
  });
  source.onload = () => { announce("拖动框选，按 A 画箭头，Enter 确认。"); requestDraw(); };
  source.onerror = () => { announce("演示图片暂时无法载入，请刷新页面。下载和接入指南仍可使用。"); sizeLabel.textContent = "图片载入失败"; document.querySelectorAll(".lab-toolbar button").forEach(button => button.disabled = true); playButton.disabled = true; };
  // The original same-origin SVG has no external resources and remains safe for PNG export.
  source.src = "assets/capture-sample.svg";
  document.addEventListener("visibilitychange", () => { if (document.hidden) stopDemo(); });
  reducedMotion.addEventListener("change", () => { if (reducedMotion.matches) stopDemo(); });
  window.addEventListener("pagehide", () => { stopDemo(); if (frame) cancelAnimationFrame(frame); }, { once: true });
})();
