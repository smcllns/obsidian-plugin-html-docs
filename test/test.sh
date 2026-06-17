#!/usr/bin/env bash
# Smoke-test the HTML Viewer plugin against a running Obsidian instance.
#
# Requires:
#   - Obsidian running with a vault open
#   - The plugin installed and enabled in that vault
#   - obsidian-cli on PATH (ships with Obsidian.app: /Applications/Obsidian.app/Contents/MacOS/obsidian-cli)
#   - jq on PATH
#
# Run:
#   bun run test
#   # or:  bash test/test.sh

set -euo pipefail

PLUGIN_ID="html-docs"
FIXTURE_REL="_html-docs-test-fixture.html"
DEFERRED_FIXTURE_REL="_html-docs-test-deferred.html"
EMBED_NOTE_REL="_html-docs-test-embed.md"
SIZED_EMBED_NOTE_REL="_html-docs-test-embed-sized.md"
CANVAS_REL="_html-docs-test-canvas.canvas"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_SRC="$ROOT/test/fixture.html"
DIST_DIR="$ROOT/dist/$PLUGIN_ID"

red()   { printf "\033[31m%s\033[0m" "$1"; }
green() { printf "\033[32m%s\033[0m" "$1"; }
gray()  { printf "\033[90m%s\033[0m" "$1"; }
amber() { printf "\033[33m%s\033[0m" "$1"; }

die() { echo "error: $*" >&2; exit 2; }

command -v obsidian-cli >/dev/null || die "obsidian-cli not on PATH (it ships inside Obsidian.app)"
command -v jq           >/dev/null || die "jq not on PATH (brew install jq)"

# Strip the "=> " prefix obsidian-cli adds to eval output.
oeval() { obsidian-cli eval code="$1" 2>/dev/null | sed 's/^=> //'; }

VAULT_PATH="$(oeval "app.vault.adapter.basePath" | sed 's/^"//; s/"$//')"
[[ -n "$VAULT_PATH" && -d "$VAULT_PATH" ]] || die "could not discover active vault (is Obsidian running with a vault open?)"

ENABLED="$(oeval "app.plugins.enabledPlugins.has('$PLUGIN_ID') ? 'yes' : 'no'" | sed 's/^"//; s/"$//')"
[[ "$ENABLED" == "yes" ]] || die "plugin '$PLUGIN_ID' is not enabled in vault '$VAULT_PATH'"

echo "building and loading current plugin"
(cd "$ROOT" && bun run build >/dev/null)
PLUGIN_DEST="$VAULT_PATH/.obsidian/plugins/$PLUGIN_ID"
[[ -d "$PLUGIN_DEST" ]] || die "plugin '$PLUGIN_ID' is not installed in vault '$VAULT_PATH'"
cp "$DIST_DIR/main.js" "$DIST_DIR/manifest.json" "$DIST_DIR/styles.css" "$PLUGIN_DEST/"
oeval "(async () => { await app.plugins.disablePlugin('$PLUGIN_ID'); await app.plugins.enablePlugin('$PLUGIN_ID'); return 'ok'; })()" >/dev/null
sleep 1

echo "vault:  $VAULT_PATH"
echo "plugin: $PLUGIN_ID (enabled)"
echo

oeval "
  window.__hvTestLeaves = new Set();
  window.__hvPreviousLeaf = app.workspace.activeLeaf;
  'ok'
" >/dev/null

FIXTURE_DEST="$VAULT_PATH/$FIXTURE_REL"
DEFERRED_FIXTURE_DEST="$VAULT_PATH/$DEFERRED_FIXTURE_REL"
EMBED_NOTE_DEST="$VAULT_PATH/$EMBED_NOTE_REL"
SIZED_EMBED_NOTE_DEST="$VAULT_PATH/$SIZED_EMBED_NOTE_REL"
CANVAS_DEST="$VAULT_PATH/$CANVAS_REL"
cp "$FIXTURE_SRC" "$FIXTURE_DEST"
cp "$FIXTURE_SRC" "$DEFERRED_FIXTURE_DEST"
printf '![[%s]]\n' "$FIXTURE_REL" > "$EMBED_NOTE_DEST"
printf '![[%s|500x320]]\n' "$FIXTURE_REL" > "$SIZED_EMBED_NOTE_DEST"
cat > "$CANVAS_DEST" <<EOF
{
  "nodes": [
    {
      "id": "html-docs-test-node",
      "type": "file",
      "file": "$FIXTURE_REL",
      "x": 0,
      "y": 0,
      "width": 500,
      "height": 320
    }
  ],
  "edges": []
}
EOF

cleanup() {
  # Close only leaves created by this test, plus any leaf displaying one of
  # the temporary files. Never detach unrelated html-docs leaves.
  local cleanup_result cleanup_status
  set +e
  # Detach test leaves, then (after a bash-side wait, since an in-eval setTimeout
  # would time out and return empty) inspect for survivors and restore focus.
  # First, defensively undo any global mutation a mid-test failure could have
  # left behind: the theme-class toggle and the deferred-leaf getViewState patch
  # used to live in in-eval try/finally blocks, but those waits now span bash
  # boundaries, so a throw before the restore eval would leak them into the live
  # app (flipped theme, patched leaf). This guaranteed cleanup path restores them.
  oeval "
    (() => {
      if (window.__hvThemeState) {
        try {
          const body = document.body;
          body.classList.toggle('theme-light', window.__hvThemeState.originalLight);
          body.classList.toggle('theme-dark', window.__hvThemeState.originalDark);
        } catch (e) {}
        delete window.__hvThemeState;
      }
      if (window.__hvDeferredState) {
        try {
          window.__hvDeferredState.fakeDeferredLeaf.getViewState = window.__hvDeferredState.originalGetViewState;
        } catch (e) {}
        delete window.__hvDeferredState;
      }
      delete window.__hvMarkdownEmbedLeaf;
      const paths = new Set(['$FIXTURE_REL', '$DEFERRED_FIXTURE_REL', '$EMBED_NOTE_REL', '$SIZED_EMBED_NOTE_REL', '$CANVAS_REL']);
      const testLeaves = window.__hvTestLeaves || new Set();
      app.workspace.iterateAllLeaves((leaf) => {
        const file = leaf.view && leaf.view.file;
        if (file && paths.has(file.path)) testLeaves.add(leaf);
      });
      window.__hvTestLeaves = testLeaves;
      for (const leaf of testLeaves) {
        try { leaf.detach(); } catch (e) {}
      }
      return 'ok';
    })()
  " >/dev/null 2>&1
  sleep 1
  cleanup_result="$(oeval "
    (() => {
      const paths = new Set(['$FIXTURE_REL', '$DEFERRED_FIXTURE_REL', '$EMBED_NOTE_REL', '$SIZED_EMBED_NOTE_REL', '$CANVAS_REL']);
      const testLeaves = window.__hvTestLeaves || new Set();

      const remaining = [];
      app.workspace.iterateAllLeaves((leaf) => {
        const file = leaf.view && leaf.view.file;
        if (file && paths.has(file.path)) {
          remaining.push({ type: leaf.view.getViewType(), path: file.path });
        }
      });

      let restoreError = null;
      if (window.__hvPreviousLeaf && !testLeaves.has(window.__hvPreviousLeaf)) {
        try {
          app.workspace.setActiveLeaf(window.__hvPreviousLeaf, { focus: true });
        } catch (e) {
          restoreError = e && e.message ? e.message : String(e);
        }
      }
      if (window.__hvListener) window.removeEventListener('message', window.__hvListener);
      delete window.__hvResults;
      delete window.__hvListener;
      delete window.__hvTestLeaves;
      delete window.__hvPreviousLeaf;

      return JSON.stringify({ remaining, restoreError });
    })()
  " 2>/dev/null)"
  cleanup_status=$?
  rm -f "$FIXTURE_DEST" "$DEFERRED_FIXTURE_DEST" "$EMBED_NOTE_DEST" "$SIZED_EMBED_NOTE_DEST" "$CANVAS_DEST"
  set -e
  if [[ "$cleanup_status" -ne 0 ]]; then
    echo "error: cleanup could not inspect Obsidian leaves" >&2
    exit 1
  fi
  if [[ -n "$cleanup_result" ]] && ! echo "$cleanup_result" | jq -e '.remaining | length == 0' >/dev/null; then
    echo "error: cleanup left temporary Obsidian test leaves open" >&2
    echo "$cleanup_result" | jq -r '.remaining[] | "  - " + .type + " " + .path' >&2
    exit 1
  fi
}
trap cleanup EXIT

# Install a parent-side listener BEFORE opening the fixture, so we don't miss
# the postMessage from the iframe's <script>.
oeval "
  window.__hvResults = null;
  if (window.__hvListener) window.removeEventListener('message', window.__hvListener);
  window.__hvListener = (e) => {
    if (e.data && e.data.type === 'html-docs-test-results') window.__hvResults = e.data;
  };
  window.addEventListener('message', window.__hvListener);
  'ok'
" >/dev/null

# Give Obsidian a moment to notice the new file, then open it.
sleep 1
oeval "
  (async () => {
    const file = app.vault.getFileByPath('$FIXTURE_REL');
    const leaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(leaf);
    await leaf.openFile(file);
    return 'ok';
  })()
" >/dev/null

# The fixture finalizes at most 4s after load. Wait a bit longer for the
# postMessage to arrive (network-dependent tests need a buffer).
sleep 6

OUTER="$(oeval "
  (async () => {
    let view = null;
    app.workspace.iterateAllLeaves((leaf) => {
      const file = leaf.view && leaf.view.file;
      if (!view && file && file.path === '$FIXTURE_REL') view = leaf.view;
    });
    const iframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
    let contentDoc = null;
    try { contentDoc = iframe ? !!iframe.contentDocument : null; } catch (e) { contentDoc = false; }
    let themeStyleInjected = false;
    if (iframe) {
      const html = await fetch(iframe.src).then((response) => response.text());
      themeStyleInjected = /<style\\b[^>]*data-html-docs-theme/i.test(html) && /color-scheme:\\s*(light|dark);/.test(html);
    }
    return JSON.stringify({
      viewType: view && view.getViewType(),
      file: view && view.file && view.file.path,
      hasIframe: !!iframe,
      sandbox: iframe && iframe.getAttribute('sandbox'),
      srcIsBlob: iframe ? iframe.src.startsWith('blob:') : false,
      contentDocAccessible: contentDoc,
      themeStyleInjected,
    });
  })()
")"

# obsidian-cli eval returns empty if its async IIFE awaits a setTimeout (the
# eval response times out before a macrotask delay resolves), so the theme
# re-render wait is driven from bash: trigger the toggle, sleep, then read the
# re-rendered state in a second short eval. Blob-URL fetches resolve fast enough
# to stay inside a single eval. State is stashed on window across evals.
oeval "
  (async () => {
    const readInjectedScheme = async (iframe) => {
      if (!iframe) return null;
      const html = await fetch(iframe.src).then((response) => response.text());
      return html.match(/color-scheme:\\s*(light|dark);/)?.[1] || null;
    };
    let view = null;
    app.workspace.iterateAllLeaves((leaf) => {
      const file = leaf.view && leaf.view.file;
      if (!view && file && file.path === '$FIXTURE_REL') view = leaf.view;
    });
    const body = document.body;
    const state = {
      originalLight: body.classList.contains('theme-light'),
      originalDark: body.classList.contains('theme-dark'),
      result: { before: null, after: null, target: null, rerendered: false, restored: false },
    };
    const iframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
    state.beforeSrc = iframe ? iframe.src : null;
    state.result.before = await readInjectedScheme(iframe);
    state.result.target = state.result.before === 'dark' ? 'light' : 'dark';
    body.classList.toggle('theme-light', state.result.target === 'light');
    body.classList.toggle('theme-dark', state.result.target === 'dark');
    window.__hvThemeState = state;
    return 'ok';
  })()
" >/dev/null
sleep 1
oeval "
  (async () => {
    const readInjectedScheme = async (iframe) => {
      if (!iframe) return null;
      const html = await fetch(iframe.src).then((response) => response.text());
      return html.match(/color-scheme:\\s*(light|dark);/)?.[1] || null;
    };
    const state = window.__hvThemeState;
    let view = null;
    app.workspace.iterateAllLeaves((leaf) => {
      const file = leaf.view && leaf.view.file;
      if (!view && file && file.path === '$FIXTURE_REL') view = leaf.view;
    });
    const refreshedIframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
    state.result.after = await readInjectedScheme(refreshedIframe);
    state.result.rerendered = !!state.beforeSrc && !!refreshedIframe && state.beforeSrc !== refreshedIframe.src;
    const body = document.body;
    body.classList.toggle('theme-light', state.originalLight);
    body.classList.toggle('theme-dark', state.originalDark);
    return 'ok';
  })()
" >/dev/null
sleep 1
THEME_RERENDER="$(oeval "
  (() => {
    const state = window.__hvThemeState;
    const body = document.body;
    state.result.restored =
      body.classList.contains('theme-light') === state.originalLight &&
      body.classList.contains('theme-dark') === state.originalDark;
    const out = JSON.stringify(state.result);
    delete window.__hvThemeState;
    return out;
  })()
")"

INNER="$(oeval "JSON.stringify(window.__hvResults)")"
REGISTRY="$(oeval "
  JSON.stringify({
    htmlViewType: app.viewRegistry.getTypeByExtension('html'),
    htmViewType: app.viewRegistry.getTypeByExtension('htm') || null,
    htmlEmbedRegistered: app.embedRegistry && app.embedRegistry.isExtensionRegistered('html'),
    htmEmbedRegistered: app.embedRegistry && app.embedRegistry.isExtensionRegistered('htm'),
  })
")"

# Trigger navigation, then read the resulting workspace state after a bash-side
# wait (see the THEME_RERENDER note on the eval timeout).
oeval "
  (async () => {
    const note = app.vault.getFileByPath('$EMBED_NOTE_REL');
    const noteLeaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(noteLeaf);
    await noteLeaf.openFile(note);
    await app.workspace.openLinkText('$FIXTURE_REL', '$EMBED_NOTE_REL', false);
    return 'ok';
  })()
" >/dev/null
sleep 1
DEDUPED_NAVIGATION="$(oeval "
  (() => {
    const htmlLeaves = [];
    app.workspace.iterateAllLeaves((leaf) => {
      const view = leaf.view;
      const file = view && view.file;
      if (file && file.path === '$FIXTURE_REL') {
        htmlLeaves.push({
          viewType: view.getViewType(),
          active: app.workspace.activeLeaf === leaf,
        });
      }
    });
    return JSON.stringify({
      htmlLeafCount: htmlLeaves.length,
      activeFile: app.workspace.activeLeaf &&
        app.workspace.activeLeaf.view &&
        app.workspace.activeLeaf.view.file &&
        app.workspace.activeLeaf.view.file.path,
      activeHtmlLeaf: htmlLeaves.some((leaf) => leaf.active),
    });
  })()
")"

# Install the deferred-state monkey-patch and trigger navigation, then read the
# result after a bash-side wait. The patched leaf and its original getViewState
# are stashed on window so the second eval can read state and restore the patch.
oeval "
  (async () => {
    const note = app.vault.getFileByPath('$EMBED_NOTE_REL');
    const fakeDeferredLeaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(fakeDeferredLeaf);
    await fakeDeferredLeaf.openFile(note);

    const originalGetViewState = fakeDeferredLeaf.getViewState.bind(fakeDeferredLeaf);
    fakeDeferredLeaf.getViewState = () => {
      const originalState = originalGetViewState();
      return {
        ...originalState,
        type: '$PLUGIN_ID',
        state: { ...(originalState.state || {}), file: '$DEFERRED_FIXTURE_REL' },
      };
    };

    window.__hvDeferredState = { fakeDeferredLeaf, originalGetViewState };
    await app.workspace.openLinkText('$DEFERRED_FIXTURE_REL', '$EMBED_NOTE_REL', false);
    return 'ok';
  })()
" >/dev/null
sleep 1
DEFERRED_STATE_NAVIGATION="$(oeval "
  (() => {
    const { fakeDeferredLeaf, originalGetViewState } = window.__hvDeferredState;
    const activeIsFakeDeferredLeaf = app.workspace.activeLeaf === fakeDeferredLeaf;
    fakeDeferredLeaf.getViewState = originalGetViewState;

    const realHtmlLeaves = [];
    app.workspace.iterateAllLeaves((leaf) => {
      const view = leaf.view;
      const file = view && view.file;
      if (file && file.path === '$DEFERRED_FIXTURE_REL') {
        realHtmlLeaves.push({
          viewType: view.getViewType(),
          active: app.workspace.activeLeaf === leaf,
        });
      }
    });

    const out = JSON.stringify({
      activeIsFakeDeferredLeaf,
      fakeDeferredLeafViewType: fakeDeferredLeaf.view && fakeDeferredLeaf.view.getViewType(),
      realHtmlLeafCount: realHtmlLeaves.length,
    });
    delete window.__hvDeferredState;
    return out;
  })()
")"

# Open the embed note in preview, then read the rendered iframe after a
# bash-side wait (see the THEME_RERENDER note on the eval timeout). The embed
# takes ~1.2s to render, so wait longer here.
oeval "
  (async () => {
    const file = app.vault.getFileByPath('$EMBED_NOTE_REL');
    const leaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(leaf);
    // Earlier blocks (DEDUPED_NAVIGATION, DEFERRED_STATE_NAVIGATION) already
    // opened this same note in other leaves, so the read eval can't re-find the
    // right one by path — stash this exact leaf and read it back.
    window.__hvMarkdownEmbedLeaf = leaf;
    await leaf.openFile(file);
    const view = leaf.view;
    if (view && view.setMode) view.setMode('preview');
    return 'ok';
  })()
" >/dev/null
sleep 2
MARKDOWN_EMBED="$(oeval "
  (async () => {
    const leaf = window.__hvMarkdownEmbedLeaf;
    const view = leaf && leaf.view;
    delete window.__hvMarkdownEmbedLeaf;
    const iframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
    const container = iframe && iframe.parentElement;
    let contentDoc = null;
    try { contentDoc = iframe ? !!iframe.contentDocument : null; } catch (e) { contentDoc = false; }
    let themeStyleInjected = false;
    if (iframe) {
      const html = await fetch(iframe.src).then((response) => response.text());
      themeStyleInjected = /<style\\b[^>]*data-html-docs-theme/i.test(html) && /color-scheme:\\s*(light|dark);/.test(html);
    }
    return JSON.stringify({
      viewType: view && view.getViewType(),
      file: view && view.file && view.file.path,
      hasIframe: !!iframe,
      sandbox: iframe && iframe.getAttribute('sandbox'),
      srcIsBlob: iframe ? iframe.src.startsWith('blob:') : false,
      contentDocAccessible: contentDoc,
      height: iframe ? Math.round(iframe.getBoundingClientRect().height) : 0,
      computedContainerHeight: container ? getComputedStyle(container).height : null,
      themeStyleInjected,
    });
  })()
")"

# Open the sized embed note in preview, then read after a bash-side wait.
oeval "
  (async () => {
    const file = app.vault.getFileByPath('$SIZED_EMBED_NOTE_REL');
    const leaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(leaf);
    await leaf.openFile(file);
    const view = leaf.view;
    if (view && view.setMode) view.setMode('preview');
    return 'ok';
  })()
" >/dev/null
sleep 2
SIZED_MARKDOWN_EMBED="$(oeval "
  (() => {
    let view = null;
    app.workspace.iterateAllLeaves((leaf) => {
      const file = leaf.view && leaf.view.file;
      if (!view && file && file.path === '$SIZED_EMBED_NOTE_REL') view = leaf.view;
    });
    const iframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
    const container = iframe && iframe.parentElement;
    return JSON.stringify({
      hasIframe: !!iframe,
      computedContainerWidth: container ? getComputedStyle(container).width : null,
      computedContainerHeight: container ? getComputedStyle(container).height : null,
    });
  })()
")"

# Open the canvas and render its html-docs node, then read after a bash-side
# wait. The canvas view/node are re-found in the read eval.
oeval "
  (async () => {
    const file = app.vault.getFileByPath('$CANVAS_REL');
    const leaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(leaf);
    await leaf.openFile(file);
    const view = leaf.view;
    const node = Array.from(view.canvas.nodes.values()).find((n) => n.file && n.file.path === '$FIXTURE_REL');
    if (node) {
      node.initialize();
      node.render();
    }
    return 'ok';
  })()
" >/dev/null
sleep 2
CANVAS_EMBED="$(oeval "
  (async () => {
    let view = null;
    app.workspace.iterateAllLeaves((leaf) => {
      const file = leaf.view && leaf.view.file;
      if (!view && file && file.path === '$CANVAS_REL') view = leaf.view;
    });
    const node = view && view.canvas && Array.from(view.canvas.nodes.values()).find((n) => n.file && n.file.path === '$FIXTURE_REL');
    const iframe = node && node.nodeEl && node.nodeEl.querySelector('iframe.html-docs-iframe');
    let contentDoc = null;
    try { contentDoc = iframe ? !!iframe.contentDocument : null; } catch (e) { contentDoc = false; }
    let themeStyleInjected = false;
    if (iframe) {
      const html = await fetch(iframe.src).then((response) => response.text());
      themeStyleInjected = /<style\\b[^>]*data-html-docs-theme/i.test(html) && /color-scheme:\\s*(light|dark);/.test(html);
    }
    return JSON.stringify({
      viewType: view && view.getViewType(),
      file: view && view.file && view.file.path,
      nodeFound: !!node,
      hasIframe: !!iframe,
      sandbox: iframe && iframe.getAttribute('sandbox'),
      srcIsBlob: iframe ? iframe.src.startsWith('blob:') : false,
      contentDocAccessible: contentDoc,
      themeStyleInjected,
      height: iframe ? Math.round(iframe.getBoundingClientRect().height) : 0,
    });
  })()
")"

failed=0
check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf "  %s %s\n" "$(green ✓)" "$label"
  else
    printf "  %s %s %s\n" "$(red ✗)" "$label" "$(gray "(expected '$expected', got '$actual')")"
    failed=1
  fi
}

echo "Outer assertions (Obsidian-side):"
check "view type is html-docs"          "$(echo "$OUTER" | jq -r .viewType)" "html-docs"
check "fixture file is open"               "$(echo "$OUTER" | jq -r .file)"      "$FIXTURE_REL"
check "iframe rendered"                    "$(echo "$OUTER" | jq -r .hasIframe)" "true"
check "sandbox is locked down"             "$(echo "$OUTER" | jq -r .sandbox)"   "allow-scripts allow-popups allow-forms"
check "iframe.src is a blob URL"           "$(echo "$OUTER" | jq -r .srcIsBlob)" "true"
check "contentDocument is cross-origin"    "$(echo "$OUTER" | jq -r .contentDocAccessible)" "false"
check "theme style injected in tab"        "$(echo "$OUTER" | jq -r .themeStyleInjected)" "true"
check "theme class re-render flips scheme" "$(echo "$THEME_RERENDER" | jq -r '.after == .target and .before != .after')" "true"
check "theme class re-render swaps blob"   "$(echo "$THEME_RERENDER" | jq -r .rerendered)" "true"
check "theme class test restores classes"  "$(echo "$THEME_RERENDER" | jq -r .restored)" "true"
check ".html routes to html-docs view"      "$(echo "$REGISTRY" | jq -r .htmlViewType)" "html-docs"
check ".htm routes to html-docs view"       "$(echo "$REGISTRY" | jq -r .htmViewType)" "html-docs"
check ".html embed registered"             "$(echo "$REGISTRY" | jq -r .htmlEmbedRegistered)" "true"
check ".htm embed registered"              "$(echo "$REGISTRY" | jq -r .htmEmbedRegistered)" "true"
check "open existing html tab from link"    "$(echo "$DEDUPED_NAVIGATION" | jq -r .htmlLeafCount)" "1"
check "existing html tab is focused"        "$(echo "$DEDUPED_NAVIGATION" | jq -r .activeFile)" "$FIXTURE_REL"
check "deferred html state is reused"       "$(echo "$DEFERRED_STATE_NAVIGATION" | jq -r .activeIsFakeDeferredLeaf)" "true"
check "deferred match avoids new html tab"  "$(echo "$DEFERRED_STATE_NAVIGATION" | jq -r .realHtmlLeafCount)" "0"

echo
echo "Embed assertions:"
check "markdown embed view is markdown"     "$(echo "$MARKDOWN_EMBED" | jq -r .viewType)" "markdown"
check "markdown embed iframe rendered"      "$(echo "$MARKDOWN_EMBED" | jq -r .hasIframe)" "true"
check "markdown embed sandbox locked down"  "$(echo "$MARKDOWN_EMBED" | jq -r .sandbox)"   "allow-scripts allow-popups allow-forms"
check "markdown embed iframe.src is blob"   "$(echo "$MARKDOWN_EMBED" | jq -r .srcIsBlob)" "true"
check "markdown embed cross-origin"         "$(echo "$MARKDOWN_EMBED" | jq -r .contentDocAccessible)" "false"
check "markdown embed theme style injected" "$(echo "$MARKDOWN_EMBED" | jq -r .themeStyleInjected)" "true"
check "markdown embed default height"       "$(echo "$MARKDOWN_EMBED" | jq -r .computedContainerHeight)" "600px"
check "sized markdown embed iframe rendered" "$(echo "$SIZED_MARKDOWN_EMBED" | jq -r .hasIframe)" "true"
check "sized markdown embed width"          "$(echo "$SIZED_MARKDOWN_EMBED" | jq -r .computedContainerWidth)" "500px"
check "sized markdown embed height"         "$(echo "$SIZED_MARKDOWN_EMBED" | jq -r .computedContainerHeight)" "320px"
check "canvas view is canvas"               "$(echo "$CANVAS_EMBED" | jq -r .viewType)" "canvas"
check "canvas node found"                   "$(echo "$CANVAS_EMBED" | jq -r .nodeFound)" "true"
check "canvas embed iframe rendered"        "$(echo "$CANVAS_EMBED" | jq -r .hasIframe)" "true"
check "canvas embed sandbox locked down"    "$(echo "$CANVAS_EMBED" | jq -r .sandbox)"   "allow-scripts allow-popups allow-forms"
check "canvas embed iframe.src is blob"     "$(echo "$CANVAS_EMBED" | jq -r .srcIsBlob)" "true"
check "canvas embed cross-origin"           "$(echo "$CANVAS_EMBED" | jq -r .contentDocAccessible)" "false"
check "canvas embed theme style injected"   "$(echo "$CANVAS_EMBED" | jq -r .themeStyleInjected)" "true"

echo
echo "Inner assertions (iframe-side, via postMessage):"
if [[ -z "$INNER" || "$INNER" == "null" ]]; then
  printf "  %s no test results received from fixture\n" "$(red ✗)"
  printf "     %s\n" "$(gray "the iframe's <script> may not have run, or postMessage was blocked")"
  failed=1
else
  pass=$(echo "$INNER" | jq -r .pass)
  fail=$(echo "$INNER" | jq -r .fail)
  skip=$(echo "$INNER" | jq -r .skip)
  printf "  %s passed · %s failed · %s skipped\n" "$(green "$pass")" "$([[ $fail -gt 0 ]] && red "$fail" || echo "$fail")" "$(amber "$skip")"
  echo "$INNER" | jq -r '.tests[] | (if .status == "pass" then "  [32m✓[0m " elif .status == "skip" then "  [33m—[0m " else "  [31m✗[0m " end) + .name + (if .detail != "" then "  [90m" + .detail + "[0m" else "" end)'
  [[ "$fail" == "0" ]] || failed=1
fi

echo
if [[ "$failed" -eq 0 ]]; then
  echo "$(green "All checks passed.")"
  exit 0
else
  echo "$(red "One or more checks failed.")"
  exit 1
fi
