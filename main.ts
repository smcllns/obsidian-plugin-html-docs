import {
	Component,
	FileView,
	getLinkpath,
	Notice,
	type OpenViewState,
	type PaneType,
	Plugin,
	TFile,
	WorkspaceLeaf,
} from "obsidian";

const VIEW_TYPE_HTML = "html-docs";
const HTML_EXTENSIONS = ["html", "htm"] as const;
type HtmlExtension = (typeof HTML_EXTENSIONS)[number];
const isHtmlExtension = (ext: string): ext is HtmlExtension =>
	(HTML_EXTENSIONS as readonly string[]).includes(ext);

interface EmbedContext {
	containerEl: HTMLElement;
}

interface EmbedRegistry {
	registerExtension(
		extension: string,
		embedCreator: (context: EmbedContext, file: TFile) => Component,
	): void;
	unregisterExtension(extension: string): void;
}

interface AppWithEmbedRegistry {
	embedRegistry?: EmbedRegistry;
}

interface RenderOptions {
	mode: "view" | "embed";
	widthPx?: number | null;
	heightPx?: number | null;
}

interface ThemeToken {
	target: string;
	source: string;
	probeProperty?: string;
	fallback?: (styles: CSSStyleDeclaration) => string;
}

type OpenLinkText = (
	linktext: string,
	sourcePath: string,
	newLeaf?: PaneType | boolean,
	openViewState?: OpenViewState,
) => Promise<void>;

const OBSIDIAN_THEME_TOKENS: ThemeToken[] = [
	{ target: "--obsidian-bg", source: "--background-primary", probeProperty: "background-color" },
	{ target: "--obsidian-bg-2", source: "--background-secondary", probeProperty: "background-color" },
	{ target: "--obsidian-text", source: "--text-normal", probeProperty: "color" },
	{ target: "--obsidian-text-muted", source: "--text-muted", probeProperty: "color" },
	{ target: "--obsidian-accent", source: "--interactive-accent", probeProperty: "background-color" },
	{ target: "--obsidian-border", source: "--background-modifier-border", probeProperty: "border-top-color" },
	{ target: "--obsidian-font", source: "--font-text", probeProperty: "font-family", fallback: (styles) => styles.fontFamily },
	{ target: "--obsidian-font-mono", source: "--font-monospace", probeProperty: "font-family" },
];

function parseDimension(value: string | null): number | null {
	if (!value) return null;
	const parsed = Number.parseInt(value, 10);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function getColorScheme(doc: Document): "light" | "dark" {
	if (doc.body.classList.contains("theme-dark")) return "dark";
	if (doc.body.classList.contains("theme-light")) return "light";
	return doc.defaultView?.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function sanitizeCssValue(value: string): string {
	const trimmed = value.trim();
	if (!trimmed || /[{};]/.test(trimmed) || /<\/style/i.test(trimmed)) return "";
	return trimmed.replace(/\s+/g, " ");
}

function resolveThemeToken(doc: Document, styles: CSSStyleDeclaration, token: ThemeToken): string {
	const sourceValue = styles.getPropertyValue(token.source).trim();
	if (!sourceValue) return sanitizeCssValue(token.fallback?.(styles) ?? "");
	if (!token.probeProperty) return sanitizeCssValue(sourceValue);

	const probe = doc.createElement("div");
	probe.style.setProperty(token.probeProperty, `var(${token.source})`);
	doc.body.appendChild(probe);
	const resolved = doc.defaultView?.getComputedStyle(probe).getPropertyValue(token.probeProperty) ?? "";
	probe.remove();
	return sanitizeCssValue(resolved || sourceValue);
}

function buildThemeStyle(doc: Document): string {
	const styles = doc.defaultView?.getComputedStyle(doc.body);
	if (!styles) throw new Error("HTML Docs: unable to read Obsidian theme styles.");

	const colorScheme = getColorScheme(doc);
	const declarations = [`color-scheme: ${colorScheme};`, `--obsidian-color-scheme: ${colorScheme};`];
	for (const token of OBSIDIAN_THEME_TOKENS) {
		const value = resolveThemeToken(doc, styles, token);
		if (value) declarations.push(`${token.target}: ${value};`);
	}

	return `:root {\n\t${declarations.join("\n\t")}\n}`;
}

function serializeDoctype(doctype: DocumentType | null): string {
	if (!doctype) return "";
	let serialized = `<!doctype ${doctype.name}`;
	if (doctype.publicId) serialized += ` PUBLIC "${doctype.publicId}"`;
	if (doctype.systemId) serialized += `${doctype.publicId ? "" : " SYSTEM"} "${doctype.systemId}"`;
	return `${serialized}>`;
}

function injectThemeStyle(html: string, themeStyle: string): string {
	const parsed = new DOMParser().parseFromString(html, "text/html");
	const style = parsed.createElement("style");
	style.setAttribute("data-html-docs-theme", "");
	style.textContent = themeStyle;
	parsed.head.appendChild(style);
	const doctype = serializeDoctype(parsed.doctype);
	return `${doctype ? `${doctype}\n` : ""}${parsed.documentElement.outerHTML}`;
}

function renderSandboxedHtml(contentEl: HTMLElement, html: string, options: RenderOptions): () => void {
	contentEl.empty();
	contentEl.addClass("html-docs-container");
	contentEl.addClass(options.mode === "view" ? "html-docs-view" : "html-docs-embed");
	const cssProps: Record<string, string> = {};
	if (options.widthPx) cssProps["--html-docs-width"] = `${options.widthPx}px`;
	if (options.heightPx) cssProps["--html-docs-height"] = `${options.heightPx}px`;
	contentEl.setCssProps(cssProps);

	// Load the document via a Blob URL rather than srcdoc so anchor
	// links (#section) and the History API navigate correctly inside
	// the page. The sandbox attribute still gives the document an
	// opaque origin regardless of URL scheme, so isolation from
	// Obsidian and the vault is preserved.
	const htmlWithTheme = injectThemeStyle(html, buildThemeStyle(contentEl.ownerDocument));
	const blobUrl = URL.createObjectURL(new Blob([htmlWithTheme], { type: "text/html" }));

	// Build the iframe fully detached so the browser never observes it
	// without the sandbox attribute. Inserting first, then setting
	// sandbox, leaves a window where the initial about:blank document
	// is created with the parent's origin — some Chromium versions
	// don't fully re-apply the sandbox on the subsequent navigation,
	// leaking same-origin privileges into user HTML.
	const iframe = contentEl.ownerDocument.createElement("iframe");
	iframe.className = "html-docs-iframe";
	// allow-scripts lets the page's JS run; omitting allow-same-origin
	// keeps it isolated from Obsidian and the user's vault.
	iframe.setAttribute("sandbox", "allow-scripts allow-popups allow-forms");
	iframe.src = blobUrl;
	contentEl.appendChild(iframe);

	return () => {
		URL.revokeObjectURL(blobUrl);
		contentEl.empty();
		contentEl.removeClass("html-docs-container");
		contentEl.removeClass("html-docs-view");
		contentEl.removeClass("html-docs-embed");
		contentEl.style.removeProperty("--html-docs-width");
		contentEl.style.removeProperty("--html-docs-height");
	};
}

class HtmlView extends FileView {
	private cleanupHtml: (() => void) | null = null;
	private renderVersion = 0;

	getViewType(): string {
		return VIEW_TYPE_HTML;
	}

	getIcon(): string {
		return "code";
	}

	canAcceptExtension(extension: string): boolean {
		return isHtmlExtension(extension);
	}

	async onLoadFile(file: TFile): Promise<void> {
		await this.readAndRender(file);
	}

	async onUnloadFile(_file: TFile): Promise<void> {
		this.renderVersion++;
		this.cleanupHtml?.();
		this.cleanupHtml = null;
	}

	async refreshTheme(): Promise<void> {
		if (!this.file) return;
		await this.readAndRender(this.file);
	}

	private async readAndRender(file: TFile): Promise<void> {
		const version = ++this.renderVersion;
		const content = await this.app.vault.cachedRead(file);
		if (version !== this.renderVersion || this.file !== file || !this.contentEl.isConnected) return;
		this.render(content);
	}

	private render(html: string): void {
		this.cleanupHtml?.();
		this.cleanupHtml = renderSandboxedHtml(this.contentEl, html, { mode: "view" });
	}
}

class HtmlEmbed extends Component {
	private cleanupHtml: (() => void) | null = null;
	private renderVersion = 0;
	private unloaded = false;

	constructor(
		private contentEl: HTMLElement,
		private plugin: HtmlDocsPlugin,
		private file: TFile,
	) {
		super();
	}

	async loadFile(): Promise<void> {
		if (this.unloaded) return;
		this.plugin.trackHtmlEmbed(this);
		const version = ++this.renderVersion;
		const content = await this.plugin.app.vault.cachedRead(this.file);
		if (this.unloaded || version !== this.renderVersion) return;
		this.cleanupHtml?.();
		this.cleanupHtml = renderSandboxedHtml(this.contentEl, content, {
			mode: "embed",
			widthPx: parseDimension(this.contentEl.getAttribute("width")),
			heightPx: parseDimension(this.contentEl.getAttribute("height")),
		});
	}

	async refreshTheme(): Promise<void> {
		await this.loadFile();
	}

	onunload(): void {
		this.unloaded = true;
		this.renderVersion++;
		this.plugin.untrackHtmlEmbed(this);
		this.cleanupHtml?.();
		this.cleanupHtml = null;
	}
}

export default class HtmlDocsPlugin extends Plugin {
	private readonly htmlEmbeds = new Set<HtmlEmbed>();
	private currentColorScheme: "light" | "dark" | null = null;
	private themeRefreshTimeout: number | null = null;

	async onload(): Promise<void> {
		this.registerView(
			VIEW_TYPE_HTML,
			(leaf: WorkspaceLeaf) => new HtmlView(leaf),
		);
		this.registerExtensions([...HTML_EXTENSIONS], VIEW_TYPE_HTML);
		this.registerExistingHtmlTabNavigation();
		this.registerThemeRefresh();

		const embedRegistry = (this.app as unknown as AppWithEmbedRegistry).embedRegistry;
		if (!embedRegistry) {
			throw new Error("HTML Docs: app.embedRegistry is unavailable; cannot register HTML embeds.");
		}
		for (const ext of HTML_EXTENSIONS) {
			embedRegistry.registerExtension(ext, (context, file) => new HtmlEmbed(context.containerEl, this, file));
			this.register(() => embedRegistry.unregisterExtension(ext));
		}

		// Obsidian hides files with unrecognized extensions in the file
		// explorer unless "Show all file types" is on; registering the
		// extension only routes the view, it doesn't add to that filter.
		const vault = this.app.vault as { getConfig?: (key: string) => unknown };
		const showUnsupported = vault.getConfig?.("showUnsupportedFiles");
		if (showUnsupported === false) {
			new Notice(
				"To see .html files in your file explorer, please enable 'Show all file types' in Settings → Files & Links.",
				10000,
			);
		}
	}

	trackHtmlEmbed(embed: HtmlEmbed): void {
		this.htmlEmbeds.add(embed);
	}

	untrackHtmlEmbed(embed: HtmlEmbed): void {
		this.htmlEmbeds.delete(embed);
	}

	private registerThemeRefresh(): void {
		const doc = this.app.workspace.containerEl.ownerDocument;
		this.currentColorScheme = getColorScheme(doc);
		const refreshIfColorSchemeChanged = () => {
			const nextColorScheme = getColorScheme(doc);
			if (nextColorScheme === this.currentColorScheme) return;
			this.currentColorScheme = nextColorScheme;
			this.scheduleThemeRefresh();
		};

		const observer = new MutationObserver(refreshIfColorSchemeChanged);
		observer.observe(doc.body, {
			attributes: true,
			attributeFilter: ["class"],
		});
		this.registerEvent(this.app.workspace.on("css-change", () => this.scheduleThemeRefresh()));
		this.register(() => {
			observer.disconnect();
			if (this.themeRefreshTimeout !== null) window.clearTimeout(this.themeRefreshTimeout);
		});
	}

	private scheduleThemeRefresh(): void {
		if (this.themeRefreshTimeout !== null) window.clearTimeout(this.themeRefreshTimeout);
		this.themeRefreshTimeout = window.setTimeout(() => {
			this.themeRefreshTimeout = null;
			void this.refreshOpenHtmlDocuments();
		}, 50);
	}

	private async refreshOpenHtmlDocuments(): Promise<void> {
		const refreshes: Promise<void>[] = [];
		this.app.workspace.iterateAllLeaves((leaf) => {
			if (leaf.view instanceof HtmlView) refreshes.push(leaf.view.refreshTheme());
		});
		for (const embed of this.htmlEmbeds) refreshes.push(embed.refreshTheme());
		await Promise.all(refreshes);
	}

	private registerExistingHtmlTabNavigation(): void {
		const workspace = this.app.workspace;
		const openLinkText = workspace.openLinkText.bind(workspace) as OpenLinkText;

		// There is no before-open event for file views, so handle the link
		// navigation path before Obsidian creates another leaf.
		const wrapper = (async (linktext, sourcePath, newLeaf, openViewState) => {
			if (!newLeaf && openViewState?.active !== false) {
				const file = this.resolveHtmlLink(linktext, sourcePath);
				const leaf = file ? this.findOpenHtmlLeaf(file) : null;
				if (leaf) {
					workspace.setActiveLeaf(leaf, { focus: true });
					return;
				}
			}

			await openLinkText(linktext, sourcePath, newLeaf, openViewState);
		}) as OpenLinkText;
		workspace.openLinkText = wrapper;

		this.register(() => {
			if (workspace.openLinkText === wrapper) workspace.openLinkText = openLinkText;
		});
	}

	private resolveHtmlLink(linktext: string, sourcePath: string): TFile | null {
		const linkpath = getLinkpath(linktext);
		const file =
			this.app.metadataCache.getFirstLinkpathDest(linkpath, sourcePath) ??
			this.app.vault.getAbstractFileByPath(linkpath);
		return file instanceof TFile && isHtmlExtension(file.extension) ? file : null;
	}

	private findOpenHtmlLeaf(file: TFile): WorkspaceLeaf | null {
		let existingLeaf: WorkspaceLeaf | null = null;
		this.app.workspace.iterateAllLeaves((leaf) => {
			if (existingLeaf) return;
			const viewState = leaf.getViewState();
			if (viewState.type !== VIEW_TYPE_HTML) return;
			const stateFile = viewState.state?.file;
			const statePath = typeof stateFile === "string" ? stateFile : null;
			const livePath = leaf.view instanceof HtmlView ? leaf.view.file?.path : null;
			if (statePath === file.path || livePath === file.path) existingLeaf = leaf;
		});
		return existingLeaf;
	}
}
