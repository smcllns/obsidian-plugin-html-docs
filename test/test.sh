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
#   npm test
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
(cd "$ROOT" && npm run build >/dev/null)
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
  cleanup_result="$(oeval "
    (async () => {
      const paths = new Set(['$FIXTURE_REL', '$DEFERRED_FIXTURE_REL', '$EMBED_NOTE_REL', '$SIZED_EMBED_NOTE_REL', '$CANVAS_REL']);
      const testLeaves = window.__hvTestLeaves || new Set();
      app.workspace.iterateAllLeaves((leaf) => {
        const file = leaf.view && leaf.view.file;
        if (file && paths.has(file.path)) testLeaves.add(leaf);
      });

      const detachErrors = [];
      for (const leaf of testLeaves) {
        try {
          leaf.detach();
        } catch (e) {
          detachErrors.push(e && e.message ? e.message : String(e));
        }
      }
      await new Promise(resolve => window.setTimeout(resolve, 300));

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

      return JSON.stringify({ remaining, detachErrors, restoreError });
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

THEME_RERENDER="$(oeval "
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
    const originalLight = body.classList.contains('theme-light');
    const originalDark = body.classList.contains('theme-dark');
    const result = {
      before: null,
      after: null,
      target: null,
      rerendered: false,
      restored: false,
    };

    try {
      const iframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
      result.before = await readInjectedScheme(iframe);
      result.target = result.before === 'dark' ? 'light' : 'dark';
      body.classList.toggle('theme-light', result.target === 'light');
      body.classList.toggle('theme-dark', result.target === 'dark');
      await new Promise(resolve => setTimeout(resolve, 300));
      const refreshedIframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
      result.after = await readInjectedScheme(refreshedIframe);
      result.rerendered = !!iframe && !!refreshedIframe && iframe.src !== refreshedIframe.src;
    } finally {
      body.classList.toggle('theme-light', originalLight);
      body.classList.toggle('theme-dark', originalDark);
      await new Promise(resolve => setTimeout(resolve, 300));
      result.restored =
        body.classList.contains('theme-light') === originalLight &&
        body.classList.contains('theme-dark') === originalDark;
    }

    return JSON.stringify(result);
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

DEDUPED_NAVIGATION="$(oeval "
  (async () => {
    const note = app.vault.getFileByPath('$EMBED_NOTE_REL');
    const noteLeaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(noteLeaf);
    await noteLeaf.openFile(note);
    await app.workspace.openLinkText('$FIXTURE_REL', '$EMBED_NOTE_REL', false);
    await new Promise(resolve => setTimeout(resolve, 300));
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

DEFERRED_STATE_NAVIGATION="$(oeval "
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

    let activeIsFakeDeferredLeaf = false;
    try {
      await app.workspace.openLinkText('$DEFERRED_FIXTURE_REL', '$EMBED_NOTE_REL', false);
      await new Promise(resolve => setTimeout(resolve, 300));
      activeIsFakeDeferredLeaf = app.workspace.activeLeaf === fakeDeferredLeaf;
    } finally {
      fakeDeferredLeaf.getViewState = originalGetViewState;
    }

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

    return JSON.stringify({
      activeIsFakeDeferredLeaf,
      fakeDeferredLeafViewType: fakeDeferredLeaf.view && fakeDeferredLeaf.view.getViewType(),
      realHtmlLeafCount: realHtmlLeaves.length,
    });
  })()
")"

MARKDOWN_EMBED="$(oeval "
  (async () => {
    const file = app.vault.getFileByPath('$EMBED_NOTE_REL');
    const leaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(leaf);
    await leaf.openFile(file);
    const view = leaf.view;
    if (view && view.setMode) view.setMode('preview');
    await new Promise(resolve => setTimeout(resolve, 1200));
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

SIZED_MARKDOWN_EMBED="$(oeval "
  (async () => {
    const file = app.vault.getFileByPath('$SIZED_EMBED_NOTE_REL');
    const leaf = app.workspace.getLeaf('tab');
    window.__hvTestLeaves.add(leaf);
    await leaf.openFile(file);
    const view = leaf.view;
    if (view && view.setMode) view.setMode('preview');
    await new Promise(resolve => setTimeout(resolve, 1200));
    const iframe = view && view.contentEl && view.contentEl.querySelector('iframe.html-docs-iframe');
    const container = iframe && iframe.parentElement;
    return JSON.stringify({
      hasIframe: !!iframe,
      computedContainerWidth: container ? getComputedStyle(container).width : null,
      computedContainerHeight: container ? getComputedStyle(container).height : null,
    });
  })()
")"

CANVAS_EMBED="$(oeval "
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
    await new Promise(resolve => setTimeout(resolve, 1200));
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
