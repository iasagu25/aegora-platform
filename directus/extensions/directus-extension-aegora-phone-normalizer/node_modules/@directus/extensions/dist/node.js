import path, { join, resolve } from "path";
import { isIn, isTypeIn, listFolders, pathToRelativeUrl, pluralize, resolvePackage } from "@directus/utils/node";
import { API_EXTENSION_TYPES, APP_EXTENSION_TYPES, APP_OR_HYBRID_EXTENSION_PACKAGE_TYPES, APP_OR_HYBRID_EXTENSION_TYPES, BUNDLE_EXTENSION_TYPES, EXTENSION_TYPES, HYBRID_EXTENSION_TYPES, NESTED_EXTENSION_TYPES } from "@directus/constants";
import fse from "fs-extra";
import { pick } from "lodash-es";
import { z } from "zod";

//#region src/shared/constants/languages.ts
const EXTENSION_LANGUAGES = ["javascript", "typescript"];

//#endregion
//#region src/shared/constants/pkg-key.ts
const EXTENSION_PKG_KEY = "directus:extension";

//#endregion
//#region src/shared/constants/shared-deps.ts
/**
* Dependencies that we guarantee are available in the global scope of the app's bundle when app
* extensions are used. These are virtually rewritten to use the existing bundled instances in the
* global scope rather than local copies
*/
const APP_SHARED_DEPS = [
	"@directus/extensions-sdk",
	"vue",
	"vue-router",
	"vue-i18n",
	"pinia"
];
/**
* Dependencies that we guarantee are available in the node_modules of the API when API extensions
* are used. The `directus:*` extensions are virtual entrypoints available in the sandbox
*/
const API_SHARED_DEPS = ["directus", "directus:api"];

//#endregion
//#region src/node/utils/generate-extensions-entrypoint.ts
function generateExtensionsEntrypoint(extensionMaps, settings) {
	const appOrHybridExtensions = [];
	const bundleExtensions = [];
	for (const [source, extensions] of Object.entries(extensionMaps)) for (const [folder, extension] of extensions.entries()) {
		const settingsForExtension = settings.find((setting) => setting.source === source && setting.folder === folder);
		if (!settingsForExtension) continue;
		if (isIn(extension.type, [...APP_EXTENSION_TYPES, ...HYBRID_EXTENSION_TYPES]) && settingsForExtension.enabled) appOrHybridExtensions.push(extension);
		if (extension.type === "bundle") {
			const appBundle = {
				...extension,
				entries: extension.entries.filter((entry) => {
					if (isIn(entry.type, [...APP_EXTENSION_TYPES, ...HYBRID_EXTENSION_TYPES]) === false) return false;
					return settings.find((setting) => setting.source === source && setting.folder === entry.name && setting.bundle === settingsForExtension.id)?.enabled ?? false;
				})
			};
			if (appBundle.entries.length > 0) bundleExtensions.push(appBundle);
		}
	}
	const appOrHybridExtensionImports = [...APP_EXTENSION_TYPES, ...HYBRID_EXTENSION_TYPES].flatMap((type) => appOrHybridExtensions.filter((extension) => extension.type === type).map((extension, i) => `import ${type}${i} from './${pathToRelativeUrl(path.resolve(extension.path, isTypeIn(extension, HYBRID_EXTENSION_TYPES) ? extension.entrypoint.app : extension.entrypoint))}';`));
	const bundleExtensionImports = bundleExtensions.map((extension, i) => extension.entries.length > 0 ? `import {${[...APP_EXTENSION_TYPES, ...HYBRID_EXTENSION_TYPES].filter((type) => extension.entries.some((entry) => entry.type === type)).map((type) => `${pluralize(type)} as ${type}Bundle${i}`).join(",")}} from './${pathToRelativeUrl(path.resolve(extension.path, extension.entrypoint.app))}';` : "");
	const extensionExports = [...APP_EXTENSION_TYPES, ...HYBRID_EXTENSION_TYPES].map((type) => `export const ${pluralize(type)} = [${appOrHybridExtensions.filter((extension) => extension.type === type).map((_, i) => `${type}${i}`).concat(bundleExtensions.map((extension, i) => extension.entries.some((entry) => entry.type === type) ? `...${type}Bundle${i}` : null).filter((e) => e !== null)).join(",")}];`);
	return `${appOrHybridExtensionImports.join("")}${bundleExtensionImports.join("")}${extensionExports.join("")}`;
}

//#endregion
//#region src/shared/schemas/options.ts
const SplitEntrypoint = z.object({
	app: z.string(),
	api: z.string()
});
const ExtensionSandboxRequestedScopes = z.object({
	request: z.optional(z.object({
		urls: z.array(z.string()),
		methods: z.array(z.union([
			z.literal("GET"),
			z.literal("POST"),
			z.literal("PATCH"),
			z.literal("PUT"),
			z.literal("DELETE")
		]))
	})),
	log: z.optional(z.object({})),
	sleep: z.optional(z.object({}))
});
const ExtensionSandboxOptions = z.optional(z.object({
	enabled: z.boolean(),
	requestedScopes: ExtensionSandboxRequestedScopes
}));
const ExtensionOptionsBundleEntry = z.union([
	z.object({
		type: z.enum(API_EXTENSION_TYPES),
		name: z.string(),
		source: z.string()
	}),
	z.object({
		type: z.enum(APP_EXTENSION_TYPES),
		name: z.string(),
		source: z.string()
	}),
	z.object({
		type: z.enum(HYBRID_EXTENSION_TYPES),
		name: z.string(),
		source: SplitEntrypoint
	})
]);
const ExtensionOptionsBase = z.object({
	host: z.string(),
	hidden: z.boolean().optional()
});
const ExtensionOptionsApp = z.object({
	type: z.enum(APP_EXTENSION_TYPES),
	path: z.string(),
	source: z.string()
});
const ExtensionOptionsApi = z.object({
	type: z.enum(API_EXTENSION_TYPES),
	path: z.string(),
	source: z.string(),
	sandbox: ExtensionSandboxOptions
});
const ExtensionOptionsHybrid = z.object({
	type: z.enum(HYBRID_EXTENSION_TYPES),
	path: SplitEntrypoint,
	source: SplitEntrypoint,
	sandbox: ExtensionSandboxOptions
});
const ExtensionOptionsBundle = z.object({
	type: z.literal("bundle"),
	partial: z.boolean().optional(),
	path: SplitEntrypoint,
	entries: z.array(ExtensionOptionsBundleEntry)
});
const ExtensionOptionsBundleEntries = z.array(ExtensionOptionsBundleEntry);
const ExtensionOptions = ExtensionOptionsBase.and(z.union([
	ExtensionOptionsApp,
	ExtensionOptionsApi,
	ExtensionOptionsHybrid,
	ExtensionOptionsBundle
]));

//#endregion
//#region src/shared/schemas/manifest.ts
const ExtensionManifest = z.object({
	name: z.string(),
	version: z.string(),
	type: z.union([z.literal("module"), z.literal("commonjs")]).optional(),
	description: z.string().optional(),
	icon: z.string().optional(),
	dependencies: z.record(z.string(), z.string()).optional(),
	devDependencies: z.record(z.string(), z.string()).optional(),
	[EXTENSION_PKG_KEY]: ExtensionOptions
});

//#endregion
//#region src/node/utils/get-extensions.ts
function getExtensionDefinition(manifest, meta) {
	const { name, version } = manifest;
	const { path: path$1, local } = meta;
	const extensionOptions = manifest[EXTENSION_PKG_KEY];
	if (extensionOptions.type === "bundle") return {
		path: path$1,
		name,
		partial: extensionOptions.partial,
		version,
		type: extensionOptions.type,
		entrypoint: {
			app: extensionOptions.path.app,
			api: extensionOptions.path.api
		},
		entries: extensionOptions.entries.map((entry) => pick(entry, "name", "type")),
		host: extensionOptions.host,
		local
	};
	else if (isTypeIn(extensionOptions, HYBRID_EXTENSION_TYPES)) return {
		path: path$1,
		name,
		version,
		type: extensionOptions.type,
		entrypoint: {
			app: extensionOptions.path.app,
			api: extensionOptions.path.api
		},
		host: extensionOptions.host,
		sandbox: extensionOptions.sandbox,
		local
	};
	else if (extensionOptions.type === "hook" || extensionOptions.type === "endpoint") return {
		path: path$1,
		name,
		version,
		type: extensionOptions.type,
		entrypoint: extensionOptions.path,
		host: extensionOptions.host,
		sandbox: extensionOptions.sandbox,
		local
	};
	else return {
		path: path$1,
		name,
		version,
		type: extensionOptions.type,
		entrypoint: extensionOptions.path,
		host: extensionOptions.host,
		local
	};
}
async function resolveFsExtensions(root) {
	root = resolve(root);
	if (!await fse.exists(root)) return /* @__PURE__ */ new Map();
	const extensionFolders = await listFolders(root, { ignoreHidden: true });
	const extensionMap = await Promise.all(extensionFolders.map(async (folder) => {
		const path$1 = join(root, folder);
		try {
			return {
				name: folder,
				path: path$1,
				manifest: await fse.readJSON(join(path$1, "package.json"))
			};
		} catch {
			return;
		}
	}));
	const extensions = /* @__PURE__ */ new Map();
	for (const extension of extensionMap.values()) {
		if (!extension) continue;
		const { name, path: path$1, manifest } = extension;
		let parsedManifest;
		try {
			parsedManifest = ExtensionManifest.parse(manifest);
		} catch (error) {
			throw new Error(`The manifest of the extension "${name}" (${path$1}) is invalid.\n${error}`);
		}
		const extensionDefinition = getExtensionDefinition(parsedManifest, {
			path: path$1,
			local: true
		});
		extensions.set(name, extensionDefinition);
	}
	return extensions;
}
async function resolveModuleExtensions(root) {
	root = resolve(root);
	let pkg;
	try {
		pkg = await fse.readJSON(join(root, "package.json"));
	} catch {
		throw new Error(`Couldn't resolve package extensions: Path "${root}" does not contain a package.json file`);
	}
	const dependencyNames = Object.keys(pkg.dependencies ?? {});
	const dependencyMap = await Promise.all(dependencyNames.map(async (name) => {
		try {
			const path$1 = resolvePackage(name, root);
			const manifest = await fse.readJSON(join(path$1, "package.json"));
			if (EXTENSION_PKG_KEY in manifest) return {
				name,
				path: path$1,
				manifest
			};
		} catch {}
	}));
	const extensions = /* @__PURE__ */ new Map();
	for (const extension of dependencyMap.values()) {
		if (!extension) continue;
		let parsedManifest;
		try {
			parsedManifest = ExtensionManifest.parse(extension.manifest);
		} catch (error) {
			throw new Error(`The manifest of the package extension "${extension.name}" is invalid.\n${error}`);
		}
		const extensionDefinition = getExtensionDefinition(parsedManifest, {
			path: extension.path,
			local: true
		});
		extensions.set(extension.name, extensionDefinition);
	}
	return extensions;
}

//#endregion
//#region src/shared/utils/define-extension.ts
function defineInterface(config) {
	return config;
}
function defineDisplay(config) {
	return config;
}
function defineLayout(config) {
	return config;
}
function defineModule(config) {
	return config;
}
function definePanel(config) {
	return config;
}
function defineHook(config) {
	return config;
}
function defineEndpoint(config) {
	return config;
}
function defineOperationApp(config) {
	return config;
}
function defineOperationApi(config) {
	return config;
}

//#endregion
export { API_EXTENSION_TYPES, API_SHARED_DEPS, APP_EXTENSION_TYPES, APP_OR_HYBRID_EXTENSION_PACKAGE_TYPES, APP_OR_HYBRID_EXTENSION_TYPES, APP_SHARED_DEPS, BUNDLE_EXTENSION_TYPES, EXTENSION_LANGUAGES, EXTENSION_PKG_KEY, EXTENSION_TYPES, ExtensionManifest, ExtensionOptions, ExtensionOptionsApi, ExtensionOptionsApp, ExtensionOptionsBase, ExtensionOptionsBundle, ExtensionOptionsBundleEntries, ExtensionOptionsBundleEntry, ExtensionOptionsHybrid, ExtensionSandboxOptions, ExtensionSandboxRequestedScopes, HYBRID_EXTENSION_TYPES, NESTED_EXTENSION_TYPES, SplitEntrypoint, defineDisplay, defineEndpoint, defineHook, defineInterface, defineLayout, defineModule, defineOperationApi, defineOperationApp, definePanel, generateExtensionsEntrypoint, getExtensionDefinition, resolveFsExtensions, resolveModuleExtensions };