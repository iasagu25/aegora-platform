import { API_EXTENSION_TYPES, APP_EXTENSION_TYPES, APP_OR_HYBRID_EXTENSION_PACKAGE_TYPES, APP_OR_HYBRID_EXTENSION_TYPES, BUNDLE_EXTENSION_TYPES, EXTENSION_TYPES, HYBRID_EXTENSION_TYPES, NESTED_EXTENSION_TYPES } from "@directus/constants";
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
export { API_EXTENSION_TYPES, API_SHARED_DEPS, APP_EXTENSION_TYPES, APP_OR_HYBRID_EXTENSION_PACKAGE_TYPES, APP_OR_HYBRID_EXTENSION_TYPES, APP_SHARED_DEPS, BUNDLE_EXTENSION_TYPES, EXTENSION_LANGUAGES, EXTENSION_PKG_KEY, EXTENSION_TYPES, ExtensionManifest, ExtensionOptions, ExtensionOptionsApi, ExtensionOptionsApp, ExtensionOptionsBase, ExtensionOptionsBundle, ExtensionOptionsBundleEntries, ExtensionOptionsBundleEntry, ExtensionOptionsHybrid, ExtensionSandboxOptions, ExtensionSandboxRequestedScopes, HYBRID_EXTENSION_TYPES, NESTED_EXTENSION_TYPES, SplitEntrypoint, defineDisplay, defineEndpoint, defineHook, defineInterface, defineLayout, defineModule, defineOperationApi, defineOperationApp, definePanel };