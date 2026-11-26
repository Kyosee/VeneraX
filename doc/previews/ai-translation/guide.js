(function initGuide() {
  const page = document.querySelector("#page");
  const sheet = document.querySelector("#sheet");
  const sheetBody = document.querySelector("#sheet-body");
  const announce = document.querySelector("#announce");
  const storageKey = "venerax.ai-translation-guide.preview.v1";
  const fresh = { provider: "google", configured: false, tested: false, detector: false, recognizer: false, enabled: false, finished: false, automaticGuide: true };
  let state = { ...fresh };
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey));
    if (saved) {
      for (const key of Object.keys(fresh)) {
        if (typeof saved[key] === typeof fresh[key]) state[key] = saved[key];
      }
      if (typeof saved.automaticGuide !== "boolean") state.automaticGuide = !state.finished;
      if (state.provider !== "ai") state.provider = "google";
    }
  } catch { /* Storage can be unavailable when opened from a file. */ }

  const steps = [
    ["连接翻译服务", "添加服务商，用两句日语试译。"],
    ["准备识别模型", "下载模型，让设备读出漫画原文。"],
    ["为这本漫画开启翻译", "打开单本开关，在阅读器查看译图。"],
  ];
  const providerNames = { google: "谷歌翻译", ai: "AI 模型" };
  const pathToComic = "漫画详情 › 右上角更多 › 开启 AI 翻译";
  const pathToReader = "阅读器 › 设置 › AI 翻译 › 阅读时翻译页面";
  let step = 0;
  let selectedProvider = state.provider;
  let showSampleTranslation = false;
  let showReaderOriginal = false;
  let opener = null;
  let openerRoute = "";
  let restoreSelector = "";

  function save() {
    try { localStorage.setItem(storageKey, JSON.stringify(state)); } catch { /* The demo also works in memory. */ }
  }
  function flags() { return [state.configured, state.detector && state.recognizer, state.enabled]; }
  function serviceAndModelsReady() { return state.configured && state.detector && state.recognizer; }
  function missingRequirements() {
    return [!state.configured && "翻译服务", !flags()[1] && "识别模型"].filter(Boolean).join("和");
  }
  function comicHint() {
    if (state.enabled) {
      return serviceAndModelsReady() ? "这本漫画已开启 AI 翻译，可以在阅读器对照原图和译图。" : `这本漫画已开启 AI 翻译，还需准备${missingRequirements()}才能看到译图。`;
    }
    return "点右上角「更多」，选择「开启 AI 翻译」。";
  }
  function nextStep() {
    const next = flags().indexOf(false);
    return next < 0 ? 2 : next;
  }
  function entryText() {
    if (state.finished) return "再看使用引导";
    return state.configured || state.detector || state.recognizer ? "继续引导" : "开始引导";
  }
  function route() {
    const name = location.hash.slice(1);
    return ["settings", "comic", "reader"].includes(name) ? name : "guide";
  }
  function icon(name) { return `<i class="icon i-${name}" aria-hidden="true"></i>`; }
  function button(action, label, style = "secondary", extra = "") {
    return `<button type="button" class="${style}" data-action="${action}" ${extra}>${label}</button>`;
  }
  function crumbs(items) {
    return `<p class="crumbs">${items.map((item, index) => `${index ? '<span aria-hidden="true">/</span>' : ""}${item}`).join("")}</p>`;
  }
  function art(translated) {
    return `<div class="art"><canvas data-seaside width="1000" height="526" role="img" aria-label="黑白漫画，一列电车沿海岸驶来"></canvas>
      <div class="bubble"><b lang="${translated ? "zh-CN" : "ja"}">${translated ? "下一站，<br>海边站。" : "次は、<br>海辺駅です。"}</b></div></div>`;
  }
  function togglePair() {
    return `<div class="segment" role="group" aria-label="切换示例原图与译图">${button("sample-original", "原图", "", `aria-pressed="${!showSampleTranslation}"`)}${button("sample-translated", "译图", "", `aria-pressed="${showSampleTranslation}"`)}</div>`;
  }
  function sampleFigure() {
    return `<figure class="comic-sample">${art(showSampleTranslation)}
      <figcaption><span>${icon("book")}海边电车 <small>／ 样页</small></span>${togglePair()}</figcaption></figure>`;
  }
  function sectionLink(action, title, description, value = "") {
    return `<button type="button" class="setting-row" data-action="${action}"><span><b>${title}</b><small>${description}</small></span><span class="row-end">${value}${icon("chevron")}</span></button>`;
  }
  function faq(question, answer) {
    return `<details class="question"><summary>${question}</summary><p>${answer}</p></details>`;
  }
  function guide() {
    const done = flags();
    const count = done.filter(Boolean).length;
    return `${crumbs(['<a href="#settings">设置</a>', '<a href="#settings">AI 翻译</a>', "使用引导"])}
      <section class="hero"><div class="hero-copy"><h1>翻译第一页漫画</h1>
      <p>把漫画气泡里的原文换成中文。<br>跟着示例走一遍，再为想读的漫画开启翻译。</p>
      ${button("start", `${entryText()} ${icon("arrow")}`, "primary hero-cta")}</div>
      <div class="print-stage">${sampleFigure()}</div></section>
      <div class="guide-columns"><section class="checklist"><header class="section-head"><h2>首次使用</h2><span class="progress-label"><i class="mini-progress" aria-hidden="true">${done.map(ok => `<i class="${ok ? "done" : ""}"></i>`).join("")}</i>${count} / 3 项就绪</span></header>
      <ol class="step-list">${steps.map(([title, text], i) => `<li><button data-action="step-${i}" class="step-row" type="button">
        <span class="step-index ${done[i] ? "done" : ""}" aria-label="${done[i] ? "已就绪" : `第 ${i + 1} 步`}">${done[i] ? "✓" : "0" + (i + 1)}</span>
        <span class="step-copy"><b>${title}</b><small>${text}</small></span>${icon("chevron")}</button></li>`).join("")}</ol></section>
      <aside class="faq"><header><span class="faq-icon">${icon("help")}</span><h2>常见问题</h2></header>
      ${faq("可以选哪些翻译服务？", "可以选「谷歌翻译」，也可以选「AI 模型」接入自己的兼容服务。保存后点「测试翻译」。")}
      ${faq("为什么阅读时还是原图？", "先确认这本漫画已开启翻译、服务测试通过、原文对应的识别模型已下载。翻译过程中会先显示原图，失败时可点阅读器顶栏的错误图标重试。")}
      ${faq("可以提前翻译整章吗？", "为这本漫画开启翻译后，点详情页的「预翻译」选择章节。后台任务的进度可以在任务页查看。")}
      </aside></div>`;
  }
  function settings() {
    return `${crumbs(["设置", "阅读体验", "AI 翻译"])}<div class="context-page"><h1>AI 翻译</h1>
      ${state.automaticGuide ? `<div class="entry-banner">
        <span class="entry-prompt">${icon("book")}第一次翻译漫画？</span>
        <div class="entry-actions">${button("start", "<span>引导</span>", "entry-open", 'title="打开翻译引导"')}
        ${button("hide-guide", "<span>跳过</span>", "entry-skip", 'title="不再提示翻译引导"')}</div></div>` : ""}
      <section class="settings-group"><h2>翻译服务</h2>${sectionLink("step-0", "LLM 服务商", "添加或切换负责翻译文本的服务", state.configured ? providerNames[state.provider] : "未配置")}
      ${sectionLink("step-0", "测试翻译", "用样例检测服务是否可用")}</section>
      <section class="settings-group"><h2>模型与语言</h2>${sectionLink("step-1", "模型管理", "在模型库中选择漫画原文所需的模型", flags()[1] ? "模型已就绪" : "尚未准备好")}</section>
      <section class="settings-group"><h2>帮助与清理</h2>${sectionLink("help", "AI 翻译怎么用", "重新查看引导和常见问题")}
      <button type="button" class="setting-row switch" role="switch" aria-checked="${state.automaticGuide}" aria-label="自动显示翻译引导" data-action="auto-guide"><span><b>自动显示翻译引导</b><small>在设置中显示入门提示，开启漫画翻译时提示缺少的配置。</small></span><span class="switch-track" aria-hidden="true"></span></button></section></div>`;
  }
  function comic() {
    return `${crumbs(["示例漫画", "漫画详情"])}<div class="context-page"><header class="title-row"><h1>漫画详情</h1>
      <div class="menu-wrap">${button("more", `${icon("more")} 更多`, "secondary", 'aria-expanded="false" aria-controls="comic-menu"')}
      <div id="comic-menu" class="pop-menu" hidden>${button("toggle-comic", state.enabled ? "关闭 AI 翻译" : "开启 AI 翻译", "menu-item")}</div></div></header>
      <article class="book-summary"><div class="cover" aria-hidden="true"><canvas data-seaside width="1000" height="526"></canvas></div><div><small class="muted">示例漫画</small><h2>海边电车</h2><p>日语原文</p><div class="actions">${button("read", "阅读", "primary")}${state.enabled ? button("pretranslate", "预翻译") : ""}</div></div></article>
      <div class="context-note">${icon("info")}<p>${comicHint()}</p></div>
      <section class="settings-group"><h2>章节</h2>${sectionLink("read", "第 1 话　靠海的车站", "打开示例阅读器")}</section></div>`;
  }
  function reader() {
    const translated = state.enabled && serviceAndModelsReady() && !showReaderOriginal;
    return `${crumbs(['<a href="#comic">漫画详情</a>', "阅读器"])}<div class="reader-page">
      <header class="reader-toolbar"><a href="#comic" class="back-link" aria-label="返回漫画详情">${icon("back")}</a>
      <div><b>海边电车</b><small>第 1 话　靠海的车站</small></div><div class="reader-actions">
      ${state.enabled && serviceAndModelsReady() ? button("flip-reader", `${icon(translated ? "image" : "language")}<span>${translated ? "查看原图" : "查看译图"}</span>`, "tool-button", `aria-label="${translated ? "查看原图" : "查看译图"}"`) : ""}
      ${button("reader-settings", `${icon("gear")}<span>设置</span>`, "tool-button", 'aria-label="设置"')}</div></header>
      <figure class="reader-paper">${art(translated)}<figcaption>1 / 1</figcaption></figure>
      <p class="reader-hint">${state.enabled && serviceAndModelsReady() ? "点顶栏按钮，在原图和译图间切换。" : state.enabled ? comicHint() : "在顶栏打开「设置」，点「AI 翻译」为本漫画开启翻译。"}</p></div>`;
  }
  function paint() {
    page.querySelectorAll("canvas[data-seaside]").forEach(canvas => window.drawSeaside(canvas));
  }
  function render() {
    const current = route();
    const pages = { guide, settings, comic, reader };
    page.innerHTML = pages[current]();
    const tab = current === "reader" ? "comic" : current;
    document.querySelectorAll(".preview-nav a").forEach(link => {
      if (link.hash === `#${tab}`) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    });
    paint();
  }
  function switchSample(translated) {
    showSampleTranslation = translated;
    const figure = page.querySelector(".comic-sample");
    const text = figure.querySelector(".bubble b");
    text.lang = translated ? "zh-CN" : "ja";
    text.innerHTML = translated ? "下一站，<br>海边站。" : "次は、<br>海辺駅です。";
    figure.querySelectorAll(".segment button").forEach((btn, i) => btn.setAttribute("aria-pressed", String(Boolean(i) === translated)));
    announce.textContent = translated ? "译图。下一站，海边站。" : "已切换为日语原图";
  }
  function modal(title, body, actions, context = "") {
    if (!sheet.open) {
      opener = document.activeElement;
      openerRoute = route();
      restoreSelector = opener?.dataset.action || "";
    }
    sheetBody.innerHTML = `<div class="sheet-header"><span>${context}</span>${button("close", "×", "icon-button", 'aria-label="关闭"')}</div>
      <h2 id="sheet-title" tabindex="-1">${title}</h2>${body}<div class="sheet-actions">${actions}</div>`;
    if (!sheet.open) sheet.showModal();
    sheet.scrollTop = 0;
    sheetBody.querySelector("h2").focus({ preventScroll: true });
  }
  function guideFooter(index) {
    const back = index ? button("prev", "上一步", "text-button") : button("close", "稍后再说", "text-button");
    const ready = flags()[index] && (index !== 0 || state.provider === selectedProvider) && (index !== 2 || serviceAndModelsReady());
    return back + button(index === 2 ? "finish" : "next", index === 2 ? "查看示例译图" : "下一步", "primary", ready ? "" : "disabled");
  }
  function serviceBody() {
    const saved = state.configured && state.provider === selectedProvider;
    const tested = saved && state.tested;
    return `<p class="sheet-intro">在「LLM 服务商」保存一个服务，再用「测试翻译」确认它能返回译文。</p>
      <fieldset class="options"><legend>服务类型</legend>${["google", "ai"].map(key => `<label><input type="radio" name="provider" value="${key}" ${selectedProvider === key ? "checked" : ""}><span><b>${providerNames[key]}</b><small>${key === "google" ? "逐句翻译，不同页之间的用词可能不一致。" : "使用自己的兼容服务，费用由服务商决定。"}</small></span></label>`).join("")}</fieldset>
      ${selectedProvider === "ai" ? `<div class="example-config"><b>AI 模型怎么填？</b><span>填服务商给你的 API 地址和 API Key，再点「获取模型」选择模型。也可以手动填写模型名。</span></div>` : ""}
      <div class="practice"><div><b>测试翻译</b><small lang="ja">こんにちは / ありがとう</small></div>${button("test", tested ? "再次测试" : saved ? "模拟测试" : "模拟保存并测试", "tonal")}</div>
      ${tested ? '<p class="success" role="status">✓　翻译成功　你好 / 谢谢</p>' : saved ? '<p class="success" role="status">✓　示例服务已保存</p>' : button("save-provider", "仅保存示例配置", "text-button")}
      ${faq("测试失败怎么办？", selectedProvider === "google" ? "先检查网络。公共接口可能限流，可以稍后再试，或切换到自己的 AI 模型。" : "核对 API 地址、密钥和模型名，再点「测试翻译」。")}`;
  }
  function modelRow(key, name, helper) {
    return `<div class="practice"><div><b>${name}</b><small>${helper}</small></div>${state[key] ? '<span class="ready">✓ 已就绪</span>' : button(`download-${key}`, "模拟下载", "tonal", `aria-label="模拟下载${name}"`)}</div>`;
  }
  function modelsBody() {
    return `<p class="sheet-intro">在「翻译偏好」选好原文和译文的语言，再打开「模型管理 › 模型库」。检测器找出字在哪里，识别器读出写了什么。</p>
      <div class="language-pair"><span>源语言 <b>日语</b></span>${icon("arrow")}<span>目标语言 <b>简体中文</b></span></div>
      ${modelRow("detector", "文本检测", "PP-OCRv5 mobile · 约 4.8 MB，各语言共用")}
      ${modelRow("recognizer", "文本识别", "Manga OCR · 日语漫画识别，约 461 MB")}
      <p class="inline-note">这是日语样页需要的两项。换一本日语漫画时，已下载的模型可以复用。</p>`;
  }
  function finalBody() {
    const readerEntry = route() === "reader";
    return `<p class="sheet-intro">翻译按漫画单独开启。用这本《海边电车》试读一页，其他漫画可以继续看原文。</p>
      <div class="where"><b>${readerEntry ? "从阅读器开启" : "从漫画详情开启"}</b><p>${readerEntry ? pathToReader : pathToComic}</p></div>
      ${serviceAndModelsReady() ? `<div class="practice"><div><b>${readerEntry ? "阅读时翻译页面" : "开启 AI 翻译"}</b><small>仅对《海边电车》生效</small></div>
        ${button("enable", `<span class="switch-track"></span>`, "switch", `role="switch" aria-label="为海边电车开启翻译" aria-checked="${state.enabled}"`)}</div>` :
      `<div class="practice"><div><b>还需要${!state.configured ? "配置翻译服务" : "准备识别模型"}</b><small>准备好后就能查看这本漫画的译图。</small></div>${button("start", "去准备", "tonal")}</div>`}
      <p class="inline-note">也可在${readerEntry ? "漫画详情页右上角的「更多」菜单开启。" : "阅读器的「设置 › AI 翻译」中打开「阅读时翻译页面」。"}</p>`;
  }
  function showStep(index, focusAction = "") {
    step = index;
    const views = [serviceBody, modelsBody, finalBody];
    const marker = `<span class="step-meter">${[0, 1, 2].map(i => `<i class="${i <= index ? "on" : ""}"></i>`).join("")}</span> 第 ${index + 1} 步，共 3 步`;
    modal(steps[index][0], views[index](), guideFooter(index), marker);
    if (focusAction) sheetBody.querySelector(`[data-action="${focusAction}"]:not(:disabled)`)?.focus({ preventScroll: true });
  }
  function toggleComic() {
    if (state.enabled || !state.automaticGuide || serviceAndModelsReady()) {
      state.enabled = !state.enabled;
      showReaderOriginal = false;
      save();
      if (sheet.open) sheet.close();
      else render();
      announce.textContent = state.enabled ? "已为海边电车开启 AI 翻译" : "已关闭本漫画的 AI 翻译";
      return;
    }
    modal("还差一点就能翻译", `<p class="sheet-intro">《海边电车》还需要准备${missingRequirements()}。引导会从缺少的那一步开始。</p>`,
      button("close", "稍后再说", "text-button") + button("start", entryText(), "primary"), "为本漫画开启 AI 翻译");
  }
  function go(name) {
    if (sheet.open) sheet.close();
    if (route() !== name) location.hash = name;
    else render();
  }
  function setAutomaticGuide(enabled) {
    state.automaticGuide = enabled;
    save();
    render();
    page.querySelector('[data-action="auto-guide"]').focus({ preventScroll: true });
    announce.textContent = enabled ? "已恢复自动提示翻译引导" : "已关闭自动提示，可从帮助与清理随时重看";
  }
  function saveProvider(tested) {
    state.provider = selectedProvider;
    state.configured = true;
    state.tested = tested;
    save();
    showStep(0, "next");
  }
  const actions = {
    start: () => showStep(state.finished && flags().every(Boolean) ? 0 : nextStep()),
    help: () => go("guide"),
    "hide-guide": () => setAutomaticGuide(false),
    "auto-guide": () => setAutomaticGuide(!state.automaticGuide),
    next: () => showStep(step + 1),
    prev: () => showStep(step - 1),
    close: () => sheet.close(),
    "sample-original": () => switchSample(false),
    "sample-translated": () => switchSample(true),
    "save-provider": () => saveProvider(false),
    test: () => saveProvider(true),
    enable() { state.enabled = !state.enabled; save(); showStep(2, "enable"); },
    finish() { state.finished = true; state.automaticGuide = false; save(); showReaderOriginal = false; go("reader"); },
    read: () => go("reader"),
    more() {
      const menu = document.querySelector("#comic-menu");
      menu.hidden = !menu.hidden;
      document.querySelector('[data-action="more"]').setAttribute("aria-expanded", String(!menu.hidden));
      if (!menu.hidden) menu.querySelector("button").focus();
    },
    "toggle-comic": toggleComic,
    "flip-reader"() { showReaderOriginal = !showReaderOriginal; render(); page.querySelector('[data-action="flip-reader"]').focus(); },
    "reader-settings"() {
      modal("阅读设置", `<div class="settings-group">${sectionLink("reader-translation", "AI 翻译", "服务、语言和本漫画的翻译开关")}</div>`, button("close", "返回阅读器", "text-button"), "阅读器设置");
    },
    "reader-translation"() {
      modal("AI 翻译", `<div class="practice"><div><b>阅读时翻译页面</b><small>仅对本漫画生效</small></div>
        ${button("toggle-comic", '<span class="switch-track"></span>', "switch", `role="switch" aria-label="阅读时翻译页面" aria-checked="${state.enabled}"`)}</div>
        ${sectionLink("start", "AI 翻译怎么用", "查看配置和阅读引导")}`, button("reader-settings", "返回阅读设置", "text-button"), "阅读器设置");
    },
    pretranslate() {
      if (!serviceAndModelsReady()) {
        const missing = !state.configured ? 0 : 1;
        modal("预翻译还未就绪", `<p class="sheet-intro">这本漫画已开启翻译。预翻译前还需准备${missingRequirements()}。</p>`,
          button("close", "返回漫画详情", "text-button") + button(`step-${missing}`, missing === 0 ? "配置翻译服务" : "模型管理", "primary"), "预翻译");
        return;
      }
      modal("选择章节", '<div class="where"><b>第 1 话　靠海的车站</b><p>在应用里可勾选章节，点「开始预翻译」，然后在任务页查看进度。</p></div>', button("close", "返回漫画详情", "primary"), "预翻译");
    },
    reset() {
      state = { ...fresh }; save(); selectedProvider = state.provider;
      showSampleTranslation = false; showReaderOriginal = false;
      go("guide"); window.scrollTo(0, 0); page.focus({ preventScroll: true }); announce.textContent = "示例进度已重置";
    },
  };
  document.addEventListener("click", event => {
    const target = event.target.closest("[data-action]");
    const menu = page.querySelector("#comic-menu:not([hidden])");
    if (menu && !event.target.closest(".menu-wrap")) {
      menu.hidden = true;
      page.querySelector('[data-action="more"]').setAttribute("aria-expanded", "false");
    }
    if (!target || target.disabled) return;
    const action = target.dataset.action;
    if (action.startsWith("step-")) return showStep(Number(action.slice(-1)));
    if (action.startsWith("download-")) {
      state[action.slice(9)] = true; save();
      return showStep(1, state.detector && state.recognizer ? "next" : `download-${state.detector ? "recognizer" : "detector"}`);
    }
    actions[action]?.();
  });
  sheetBody.addEventListener("change", event => {
    if (event.target.name !== "provider") return;
    selectedProvider = event.target.value;
    showStep(0);
    sheetBody.querySelector("input:checked").focus();
  });
  sheet.addEventListener("close", () => {
    if (sheet.open) return;
    selectedProvider = state.provider;
    render();
    if (openerRoute === route()) {
      const target = opener?.isConnected ? opener : page.querySelector(`[data-action="${restoreSelector}"]`);
      (target?.offsetWidth ? target : page.querySelector('[data-action="more"]') || page).focus({ preventScroll: true });
    }
  });
  document.addEventListener("keydown", event => {
    const menu = page.querySelector("#comic-menu:not([hidden])");
    if (event.key === "Escape" && !sheet.open && menu) {
      const more = page.querySelector('[data-action="more"]');
      menu.hidden = true; more.setAttribute("aria-expanded", "false"); more.focus();
    }
  });
  window.addEventListener("hashchange", () => {
    if (sheet.open) sheet.close();
    render(); window.scrollTo(0, 0); page.focus({ preventScroll: true });
  });
  render();
})();
