// Quire preview runtime: syntax highlighting (highlight.js), math (KaTeX) and
// diagrams (Mermaid) for the Markdown/code preview. Mermaid and KaTeX are
// loaded only when the page needs them. The app calls quireUpdate(html) to
// swap in a new body without reloading, so scroll position and rendered
// diagrams survive typing.
(function () {
    "use strict";
    const base = document.currentScript.src.replace(/[^/]*$/, "");
    const dark = window.matchMedia("(prefers-color-scheme: dark)");
    const diagramCache = new Map();   // theme + source -> svg
    const loading = {};
    let generation = 0;
    let diagramSeq = 0;

    function load(path) {
        if (!loading[path]) {
            loading[path] = new Promise((resolve, reject) => {
                const s = document.createElement("script");
                s.src = base + path;
                s.onload = resolve;
                s.onerror = () => reject(new Error("could not load " + path));
                document.head.appendChild(s);
            });
        }
        return loading[path];
    }

    // MARK: Code

    function highlight(root) {
        for (const code of root.querySelectorAll("pre > code[class*='language-']")) {
            const pre = code.parentElement;
            if (pre.dataset.lang) continue;
            const lang = (code.className.match(/language-(\S+)/) || [])[1] || "";
            pre.dataset.lang = lang;
            if (window.hljs && hljs.getLanguage(lang) && code.textContent.length < 200000) {
                hljs.highlightElement(code);
            }
            const copy = document.createElement("button");
            copy.className = "copy";
            copy.type = "button";
            copy.textContent = "Copy";
            copy.addEventListener("click", () => {
                copyText(code.textContent);
                copy.textContent = "Copied";
                setTimeout(() => { copy.textContent = "Copy"; }, 1200);
            });
            pre.appendChild(copy);
        }
    }

    function copyText(text) {
        const area = document.createElement("textarea");
        area.value = text;
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.appendChild(area);
        area.select();
        document.execCommand("copy");
        area.remove();
    }

    // MARK: Math

    async function renderMath(root) {
        const nodes = root.querySelectorAll(".math:not([data-done])");
        if (!nodes.length) return;
        try { await load("katex/katex.min.js"); } catch (e) { return; }
        for (const el of nodes) {
            const tex = el.textContent;
            el.dataset.done = "1";
            try {
                katex.render(tex, el, { displayMode: el.classList.contains("math-display"), throwOnError: false });
            } catch (e) {
                el.classList.add("math-error");
                el.title = e.message;
            }
        }
    }

    // MARK: Diagrams

    function mermaidTheme() { return dark.matches ? "dark" : "light"; }

    // Mermaid's "base" theme tuned to the preview's palette.
    const diagramPalettes = {
        light: {
            background: "#ffffff", primaryColor: "#eef4ff", primaryBorderColor: "#7aa7e8", primaryTextColor: "#1d1d1f",
            secondaryColor: "#f3f0ff", secondaryBorderColor: "#a99be6", tertiaryColor: "#f6f8fa", tertiaryBorderColor: "#d8d8dc",
            lineColor: "#8a8f98", textColor: "#1d1d1f", clusterBkg: "#f7f8fa", clusterBorder: "#d8d8dc",
            edgeLabelBackground: "#ffffff", noteBkgColor: "#fff8db", noteBorderColor: "#e5c76b", noteTextColor: "#1d1d1f",
            actorBkg: "#eef4ff", actorBorder: "#7aa7e8", actorTextColor: "#1d1d1f", actorLineColor: "#b8bcc4",
            signalColor: "#5a5f68", signalTextColor: "#1d1d1f", labelBoxBkgColor: "#eef4ff", labelBoxBorderColor: "#7aa7e8",
            pie1: "#7aa7e8", pie2: "#a99be6", pie3: "#6fc2a0", pie4: "#f0b86e", pie5: "#e88a8a", pie6: "#86c5e3",
            pieStrokeColor: "#ffffff", pieOuterStrokeColor: "#d8d8dc", pieSectionTextColor: "#1d1d1f", pieTitleTextColor: "#1d1d1f",
        },
        dark: {
            background: "#1e1f22", primaryColor: "#1f2b3d", primaryBorderColor: "#4f7fc4", primaryTextColor: "#e6e6e8",
            secondaryColor: "#2a2440", secondaryBorderColor: "#7d6cc4", tertiaryColor: "#26272c", tertiaryBorderColor: "#3a3b40",
            lineColor: "#8b8d94", textColor: "#e6e6e8", clusterBkg: "#25262b", clusterBorder: "#3a3b40",
            edgeLabelBackground: "#1e1f22", noteBkgColor: "#3a3420", noteBorderColor: "#8a7636", noteTextColor: "#e6e6e8",
            actorBkg: "#1f2b3d", actorBorder: "#4f7fc4", actorTextColor: "#e6e6e8", actorLineColor: "#4a4c52",
            signalColor: "#a9abb2", signalTextColor: "#e6e6e8", labelBoxBkgColor: "#1f2b3d", labelBoxBorderColor: "#4f7fc4",
            pie1: "#4f7fc4", pie2: "#7d6cc4", pie3: "#3f9a78", pie4: "#c4893f", pie5: "#c45f5f", pie6: "#4f9cc0",
            pieStrokeColor: "#1e1f22", pieOuterStrokeColor: "#3a3b40", pieSectionTextColor: "#ffffff", pieTitleTextColor: "#e6e6e8",
        },
    };

    function mermaidConfig(theme) {
        return {
            startOnLoad: false,
            securityLevel: "strict",
            theme: "base",
            themeVariables: Object.assign({
                fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
                fontSize: "14px",
            }, diagramPalettes[theme]),
            flowchart: { curve: "basis", padding: 14 },
            sequence: { useMaxWidth: true, mirrorActors: false },
        };
    }
    // The editor's diagram widgets use the same look.
    window.quireMermaidConfig = mermaidConfig;
    window.quireLoad = load;

    async function renderDiagrams(root, gen) {
        const blocks = root.querySelectorAll("pre.mermaid");
        if (!blocks.length) return;
        try { await load("mermaid/mermaid.min.js"); } catch (e) { return; }
        const theme = mermaidTheme();
        mermaid.initialize(mermaidConfig(theme));
        for (const pre of blocks) {
            if (gen !== generation) return;   // a newer update replaced the page
            const source = pre.textContent;
            const key = theme + "\u0000" + source;
            const figure = document.createElement("figure");
            figure.className = "diagram";
            figure.dataset.source = source;
            if (pre.dataset.sourcepos) figure.dataset.sourcepos = pre.dataset.sourcepos;
            let svg = diagramCache.get(key);
            if (!svg) {
                const id = "quire-diagram-" + (++diagramSeq);
                try {
                    svg = (await mermaid.render(id, source)).svg;
                    if (diagramCache.size > 200) diagramCache.clear();
                    diagramCache.set(key, svg);
                } catch (e) {
                    document.getElementById("d" + id)?.remove();
                    document.getElementById(id)?.remove();
                    figure.classList.add("diagram-error");
                    const msg = document.createElement("div");
                    msg.className = "diagram-error-message";
                    msg.textContent = "Diagram error: " + String(e.message || e).trim();
                    const src = document.createElement("pre");
                    src.textContent = source;
                    figure.append(msg, src);
                }
                if (gen !== generation) return;
            }
            if (svg) figure.innerHTML = svg;
            if (pre.isConnected) pre.replaceWith(figure);
        }
    }

    // Re-render diagrams in the new colour scheme.
    dark.addEventListener("change", () => {
        for (const fig of document.querySelectorAll("figure.diagram")) {
            const pre = document.createElement("pre");
            pre.className = "mermaid";
            pre.textContent = fig.dataset.source;
            if (fig.dataset.sourcepos) pre.dataset.sourcepos = fig.dataset.sourcepos;
            fig.replaceWith(pre);
        }
        renderDiagrams(document.body, ++generation);
    });

    // MARK: Scroll sync

    // Scrolls so the block covering source line `line` (fractional: 12.5 is halfway through
    // line 12) is at the top, interpolating between blocks by their line ranges.
    // Innermost blocks with their source lines and positions, top to bottom.
    function sourceBlocks() {
        const blocks = [];
        for (const el of document.body.querySelectorAll("[data-sourcepos]")) {
            // Innermost blocks only (paragraphs, headings, code, cells…); inline math has positions too.
            if (el.tagName === "SPAN" || el.querySelector("[data-sourcepos]:not(span)")) continue;
            const m = /^(\d+):\d+-(\d+):\d+$/.exec(el.dataset.sourcepos);
            if (!m) continue;
            const top = el.getBoundingClientRect().top + window.scrollY;
            blocks.push({ start: +m[1], end: +m[2] + 1, top: top, bottom: top + el.offsetHeight });
        }
        return blocks;
    }

    let syncedAt = 0;   // when the app last scrolled us, so that scroll isn't echoed back

    // Scrolls so the block covering source line `line` (fractional: 12.5 is halfway through
    // line 12) is at the top, interpolating between blocks by their line ranges.
    window.quireScrollToLine = function (line, atEnd) {
        syncedAt = Date.now();
        if (atEnd) { window.scrollTo(0, document.documentElement.scrollHeight); return; }
        const blocks = sourceBlocks();
        if (!blocks.length || line < blocks[0].start) { window.scrollTo(0, 0); return; }
        let target = 0;
        for (let i = 0; i < blocks.length; i++) {
            const b = blocks[i];
            if (line < b.start) {
                // Between blocks: slide from the end of the previous block to the start of this one.
                const prev = blocks[i - 1];
                const f = (line - prev.end) / Math.max(b.start - prev.end, 1);
                target = prev.bottom + (b.top - prev.bottom) * Math.min(Math.max(f, 0), 1);
                break;
            }
            if (line < b.end) {
                target = b.top + (b.bottom - b.top) * (line - b.start) / Math.max(b.end - b.start, 1);
                break;
            }
            target = b.bottom;
        }
        window.scrollTo(0, Math.max(0, target - 12));
    };

    // The source line at the top of the preview (the inverse of quireScrollToLine).
    function lineAtTop() {
        const y = window.scrollY + 12;
        const blocks = sourceBlocks();
        if (!blocks.length || y <= blocks[0].top) return 1;
        for (let i = 0; i < blocks.length; i++) {
            const b = blocks[i];
            if (y < b.top) {
                const prev = blocks[i - 1];
                const f = (y - prev.bottom) / Math.max(b.top - prev.bottom, 1);
                return prev.end + (b.start - prev.end) * Math.min(Math.max(f, 0), 1);
            }
            if (y < b.bottom) return b.start + (b.end - b.start) * (y - b.top) / Math.max(b.bottom - b.top, 1);
        }
        return blocks[blocks.length - 1].end;
    }

    // When the reader scrolls the preview, the editor follows.
    let scrollQueued = false;
    window.addEventListener("scroll", () => {
        if (Date.now() - syncedAt < 250 || scrollQueued || !window.webkit?.messageHandlers?.quireScroll) return;
        scrollQueued = true;
        // A timer rather than requestAnimationFrame, which stops while the window is covered.
        setTimeout(() => {
            scrollQueued = false;
            const atEnd = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
            window.webkit.messageHandlers.quireScroll.postMessage({ line: lineAtTop(), atEnd: atEnd });
        }, 16);
    }, { passive: true });

    // MARK: Entry points

    async function enhance() {
        const gen = ++generation;
        highlight(document.body);
        await renderMath(document.body);
        await renderDiagrams(document.body, gen);
    }

    window.quireUpdate = function (html) {
        document.body.innerHTML = html;
        return enhance();
    };

    window.quireReady = new Promise((resolve) => {
        const start = () => enhance().then(resolve, resolve);
        if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
        else start();
    });
})();
