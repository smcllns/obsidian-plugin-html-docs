# Add source-mode editing for `.html` files

## Summary

Today the plugin renders `.html` files in a read-only sandboxed iframe. If I spot a typo in a memo, I have to leave Obsidian to fix it.

Add a **source-mode toggle** so I can edit raw HTML inline with syntax highlighting, then flip back to the rendered preview — the pencil/book pattern Obsidian uses for Markdown.

## Scope — read this first

This is a **surgical addition**, not a redesign.

- **Net change budget: ~80 lines across all files.** If your diff exceeds this, every additional line needs strong justification in the PR description — assume the reviewer's default is "cut it."
- **Only one class changes: `HtmlView`.** Do not touch `renderSandboxedHtml`, `HtmlEmbed`, `injectThemeStyle`, `serializeDoctype`, `HtmlDocsPlugin`, embed registration, link navigation, or theme variable injection.
- **No new source files.** Everything stays in `main.ts`. No new directories, no factory extraction, no refactors.
- **No additions beyond the outcomes below.** No settings panel, no command palette entries, no extra keyboard shortcuts (CodeMirror's defaults are enough), no preferences, no toolbar beyond the single header toggle, no status bar items, no new icons besides pencil/book.
- **If you find yourself wanting to "while we're here..." — don't.** Open a follow-up issue instead.

## Outcomes

- [ ] A single toggle button in the top-right view header (`ItemView.addAction`):
  - **Pencil** icon when in preview → switches to source.
  - **Book** icon when in source → switches to preview.
- [ ] Source mode shows the file's raw HTML in CodeMirror 6 with `@codemirror/lang-html` syntax highlighting.
- [ ] Edits autosave to disk via `TextFileView.requestSave()`.
- [ ] Toggling to preview re-renders the iframe from the current editor buffer (not from disk).
- [ ] Theme refresh (dark/light toggle, `css-change`) does not clobber the source editor. Simplest acceptable implementation: skip the preview re-render while source mode is active.
- [ ] Existing iframe sandbox model is unchanged: Blob URL, `sandbox="allow-scripts allow-popups allow-forms"`, no `allow-same-origin`, sandbox attribute set before `src`. See `main.ts:142-154` and the explanatory comment.
- [ ] `HtmlEmbed` (HTML embeds in markdown/canvas) stays read-only — no toggle, no editor.
- [ ] All existing behavior preserved: cross-file link navigation, doctype preservation, theme variable injection, "Show all file types" notice.

## Approach

Switch `HtmlView` from `FileView` to `TextFileView`. `TextFileView` provides:

- `setViewData(data, clear)` — Obsidian calls this with file contents on load.
- `getViewData()` — Obsidian calls this on save.
- `requestSave()` — debounced autosave; trigger from CodeMirror's `updateListener` when `docChanged`.

`HtmlView.contentEl` holds two child divs: a **source pane** containing a CodeMirror 6 `EditorView`, and a **preview pane** containing the existing iframe pipeline driven from `this.data` instead of `vault.cachedRead`. The toggle action shows/hides the two panes; switching to preview re-renders the iframe from the current buffer.

## Dependencies

- Update `esbuild.config.mjs` `external` to match the [obsidian-sample-plugin](https://github.com/obsidianmd/obsidian-sample-plugin/blob/master/esbuild.config.mjs) list so `@codemirror/state`, `@codemirror/view`, `@codemirror/language`, `@codemirror/commands`, `@codemirror/search`, `@lezer/*` resolve at runtime.
- `npm install @codemirror/lang-html` — bundled (~30KB gzipped). This is the only new bundled dep.

## Out of scope (reject even if tempting)

- WYSIWYG / `contenteditable` editing.
- Split-pane (simultaneous source + preview).
- Settings panel of any kind (font, tab size, line wrap, line numbers toggle, theme overrides, etc.).
- Editing `HtmlEmbed`s in markdown notes.
- Format-on-save, prettier, lint, autocomplete beyond CodeMirror defaults.
- Status bar items, new commands, new hotkeys.
- Refactoring existing code "while we're here."
- Splitting `main.ts` into multiple files.

## Validation

You're running in a cloud sandbox without an Obsidian instance — full UI validation is the reviewer's job. Your job is to make the code obviously correct so it builds, types check, and the existing integration test (`test/test.sh`) would still pass when the reviewer runs it locally.

**What you must verify before opening the PR:**

- `npm run build` succeeds with no errors.
- TypeScript type-checks cleanly (no `any` regressions, no `@ts-ignore` added).
- ESLint passes (`npx eslint .` or whatever `package.json` defines).
- The built `main.js` size is in a sane range (not megabytes — only `@codemirror/lang-html` is newly bundled).
- You did not modify `test/test.sh` or `test/fixture.html`. The existing integration test asserts the current preview behavior — your changes should not break it.

**What the reviewer will verify locally before merging** (the human runs these — don't try to script them):

1. Open an `.html` file in their vault. Preview renders unchanged.
2. Click pencil → source pane shows raw HTML with syntax highlighting.
3. Edit one word. Wait for autosave. `git diff` shows **only that word changed** — no unrelated whitespace or attribute churn.
4. Click book → preview reflects the edit.
5. Toggle Obsidian dark/light while in source mode. Editor state and focus are preserved.
6. Embed an `.html` file in a markdown note — embed renders, has no toggle button.
7. `Cmd+click` an internal link to another `.html` file — still navigates to an existing tab if open.
8. Run `npm test` against a vault with the plugin installed — all existing assertions still pass.

## PR description requirements

The agent opening the PR must include:

- **Final `main.js` (bundle) size** and **net line additions** across all changed files. If either materially exceeds the budget in the Scope section, justify each delta — the reviewer's default is "cut it."
- **What changed** at the class/function level (a 3–5 bullet list — no prose).
- **Explicit note that screenshots are pending reviewer validation** — the reviewer will add them as a PR comment before merge. The PR will not be merged until the screenshots are attached.
