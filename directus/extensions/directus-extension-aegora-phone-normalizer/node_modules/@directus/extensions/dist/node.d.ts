import { API_EXTENSION_TYPES, APP_EXTENSION_TYPES, APP_OR_HYBRID_EXTENSION_PACKAGE_TYPES, APP_OR_HYBRID_EXTENSION_TYPES, BUNDLE_EXTENSION_TYPES, EXTENSION_TYPES, HYBRID_EXTENSION_TYPES, NESTED_EXTENSION_TYPES } from "@directus/constants";
import { z } from "zod";
import { ApiExtension, ApiExtensionContext, ApiExtensionType, ApiOutput, AppExtension, AppExtensionConfigs, AppExtensionType, AppField, BundleExtension, BundleExtensionEntry, BundleExtensionType, DisplayConfig, DisplayFieldsFunction, EndpointConfig, EndpointExtensionContext, Extension, ExtensionOptionsContext, ExtensionSettings, ExtensionType, HookConfig, HookExtensionContext, HybridExtension, HybridExtensionType, InterfaceConfig, LayoutConfig, LayoutProps, LayoutState, ModuleConfig, NestedExtensionType, OperationApiConfig, OperationAppConfig, OperationContext, OperationHandler, Panel, PanelConfig, PanelQuery, Prettify, RegisterFunctions, ShowSelect } from "@directus/types";

//#region src/node/utils/generate-extensions-entrypoint.d.ts
declare function generateExtensionsEntrypoint(extensionMaps: {
  local: Map<string, Extension>;
  registry: Map<string, Extension>;
  module: Map<string, Extension>;
}, settings: ExtensionSettings[]): string;
//#endregion
//#region src/shared/schemas/manifest.d.ts
declare const ExtensionManifest: z.ZodObject<{
  name: z.ZodString;
  version: z.ZodString;
  type: z.ZodOptional<z.ZodUnion<readonly [z.ZodLiteral<"module">, z.ZodLiteral<"commonjs">]>>;
  description: z.ZodOptional<z.ZodString>;
  icon: z.ZodOptional<z.ZodString>;
  dependencies: z.ZodOptional<z.ZodRecord<z.ZodString, z.ZodString>>;
  devDependencies: z.ZodOptional<z.ZodRecord<z.ZodString, z.ZodString>>;
  "directus:extension": z.ZodIntersection<z.ZodObject<{
    host: z.ZodString;
    hidden: z.ZodOptional<z.ZodBoolean>;
  }, z.core.$strip>, z.ZodUnion<readonly [z.ZodObject<{
    type: z.ZodEnum<{
      interface: "interface";
      display: "display";
      layout: "layout";
      module: "module";
      panel: "panel";
      theme: "theme";
    }>;
    path: z.ZodString;
    source: z.ZodString;
  }, z.core.$strip>, z.ZodObject<{
    type: z.ZodEnum<{
      hook: "hook";
      endpoint: "endpoint";
    }>;
    path: z.ZodString;
    source: z.ZodString;
    sandbox: z.ZodOptional<z.ZodObject<{
      enabled: z.ZodBoolean;
      requestedScopes: z.ZodObject<{
        request: z.ZodOptional<z.ZodObject<{
          urls: z.ZodArray<z.ZodString>;
          methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
        }, z.core.$strip>>;
        log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
        sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
      }, z.core.$strip>;
    }, z.core.$strip>>;
  }, z.core.$strip>, z.ZodObject<{
    type: z.ZodEnum<{
      operation: "operation";
    }>;
    path: z.ZodObject<{
      app: z.ZodString;
      api: z.ZodString;
    }, z.core.$strip>;
    source: z.ZodObject<{
      app: z.ZodString;
      api: z.ZodString;
    }, z.core.$strip>;
    sandbox: z.ZodOptional<z.ZodObject<{
      enabled: z.ZodBoolean;
      requestedScopes: z.ZodObject<{
        request: z.ZodOptional<z.ZodObject<{
          urls: z.ZodArray<z.ZodString>;
          methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
        }, z.core.$strip>>;
        log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
        sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
      }, z.core.$strip>;
    }, z.core.$strip>>;
  }, z.core.$strip>, z.ZodObject<{
    type: z.ZodLiteral<"bundle">;
    partial: z.ZodOptional<z.ZodBoolean>;
    path: z.ZodObject<{
      app: z.ZodString;
      api: z.ZodString;
    }, z.core.$strip>;
    entries: z.ZodArray<z.ZodUnion<readonly [z.ZodObject<{
      type: z.ZodEnum<{
        hook: "hook";
        endpoint: "endpoint";
      }>;
      name: z.ZodString;
      source: z.ZodString;
    }, z.core.$strip>, z.ZodObject<{
      type: z.ZodEnum<{
        interface: "interface";
        display: "display";
        layout: "layout";
        module: "module";
        panel: "panel";
        theme: "theme";
      }>;
      name: z.ZodString;
      source: z.ZodString;
    }, z.core.$strip>, z.ZodObject<{
      type: z.ZodEnum<{
        operation: "operation";
      }>;
      name: z.ZodString;
      source: z.ZodObject<{
        app: z.ZodString;
        api: z.ZodString;
      }, z.core.$strip>;
    }, z.core.$strip>]>>;
  }, z.core.$strip>]>>;
}, z.core.$strip>;
type ExtensionManifest = z.infer<typeof ExtensionManifest>;
//#endregion
//#region src/shared/schemas/options.d.ts
declare const SplitEntrypoint: z.ZodObject<{
  app: z.ZodString;
  api: z.ZodString;
}, z.core.$strip>;
type SplitEntrypoint = z.infer<typeof SplitEntrypoint>;
declare const ExtensionSandboxRequestedScopes: z.ZodObject<{
  request: z.ZodOptional<z.ZodObject<{
    urls: z.ZodArray<z.ZodString>;
    methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
  }, z.core.$strip>>;
  log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
  sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
}, z.core.$strip>;
declare const ExtensionSandboxOptions: z.ZodOptional<z.ZodObject<{
  enabled: z.ZodBoolean;
  requestedScopes: z.ZodObject<{
    request: z.ZodOptional<z.ZodObject<{
      urls: z.ZodArray<z.ZodString>;
      methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
    }, z.core.$strip>>;
    log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
    sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
  }, z.core.$strip>;
}, z.core.$strip>>;
type ExtensionSandboxOptions = z.infer<typeof ExtensionSandboxOptions>;
type ExtensionSandboxRequestedScopes = z.infer<typeof ExtensionSandboxRequestedScopes>;
declare const ExtensionOptionsBundleEntry: z.ZodUnion<readonly [z.ZodObject<{
  type: z.ZodEnum<{
    hook: "hook";
    endpoint: "endpoint";
  }>;
  name: z.ZodString;
  source: z.ZodString;
}, z.core.$strip>, z.ZodObject<{
  type: z.ZodEnum<{
    interface: "interface";
    display: "display";
    layout: "layout";
    module: "module";
    panel: "panel";
    theme: "theme";
  }>;
  name: z.ZodString;
  source: z.ZodString;
}, z.core.$strip>, z.ZodObject<{
  type: z.ZodEnum<{
    operation: "operation";
  }>;
  name: z.ZodString;
  source: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
}, z.core.$strip>]>;
type ExtensionOptionsBundleEntry = z.infer<typeof ExtensionOptionsBundleEntry>;
declare const ExtensionOptionsBase: z.ZodObject<{
  host: z.ZodString;
  hidden: z.ZodOptional<z.ZodBoolean>;
}, z.core.$strip>;
declare const ExtensionOptionsApp: z.ZodObject<{
  type: z.ZodEnum<{
    interface: "interface";
    display: "display";
    layout: "layout";
    module: "module";
    panel: "panel";
    theme: "theme";
  }>;
  path: z.ZodString;
  source: z.ZodString;
}, z.core.$strip>;
declare const ExtensionOptionsApi: z.ZodObject<{
  type: z.ZodEnum<{
    hook: "hook";
    endpoint: "endpoint";
  }>;
  path: z.ZodString;
  source: z.ZodString;
  sandbox: z.ZodOptional<z.ZodObject<{
    enabled: z.ZodBoolean;
    requestedScopes: z.ZodObject<{
      request: z.ZodOptional<z.ZodObject<{
        urls: z.ZodArray<z.ZodString>;
        methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
      }, z.core.$strip>>;
      log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
      sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
    }, z.core.$strip>;
  }, z.core.$strip>>;
}, z.core.$strip>;
declare const ExtensionOptionsHybrid: z.ZodObject<{
  type: z.ZodEnum<{
    operation: "operation";
  }>;
  path: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
  source: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
  sandbox: z.ZodOptional<z.ZodObject<{
    enabled: z.ZodBoolean;
    requestedScopes: z.ZodObject<{
      request: z.ZodOptional<z.ZodObject<{
        urls: z.ZodArray<z.ZodString>;
        methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
      }, z.core.$strip>>;
      log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
      sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
    }, z.core.$strip>;
  }, z.core.$strip>>;
}, z.core.$strip>;
declare const ExtensionOptionsBundle: z.ZodObject<{
  type: z.ZodLiteral<"bundle">;
  partial: z.ZodOptional<z.ZodBoolean>;
  path: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
  entries: z.ZodArray<z.ZodUnion<readonly [z.ZodObject<{
    type: z.ZodEnum<{
      hook: "hook";
      endpoint: "endpoint";
    }>;
    name: z.ZodString;
    source: z.ZodString;
  }, z.core.$strip>, z.ZodObject<{
    type: z.ZodEnum<{
      interface: "interface";
      display: "display";
      layout: "layout";
      module: "module";
      panel: "panel";
      theme: "theme";
    }>;
    name: z.ZodString;
    source: z.ZodString;
  }, z.core.$strip>, z.ZodObject<{
    type: z.ZodEnum<{
      operation: "operation";
    }>;
    name: z.ZodString;
    source: z.ZodObject<{
      app: z.ZodString;
      api: z.ZodString;
    }, z.core.$strip>;
  }, z.core.$strip>]>>;
}, z.core.$strip>;
declare const ExtensionOptionsBundleEntries: z.ZodArray<z.ZodUnion<readonly [z.ZodObject<{
  type: z.ZodEnum<{
    hook: "hook";
    endpoint: "endpoint";
  }>;
  name: z.ZodString;
  source: z.ZodString;
}, z.core.$strip>, z.ZodObject<{
  type: z.ZodEnum<{
    interface: "interface";
    display: "display";
    layout: "layout";
    module: "module";
    panel: "panel";
    theme: "theme";
  }>;
  name: z.ZodString;
  source: z.ZodString;
}, z.core.$strip>, z.ZodObject<{
  type: z.ZodEnum<{
    operation: "operation";
  }>;
  name: z.ZodString;
  source: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
}, z.core.$strip>]>>;
type ExtensionOptionsBundleEntries = z.infer<typeof ExtensionOptionsBundleEntries>;
declare const ExtensionOptions: z.ZodIntersection<z.ZodObject<{
  host: z.ZodString;
  hidden: z.ZodOptional<z.ZodBoolean>;
}, z.core.$strip>, z.ZodUnion<readonly [z.ZodObject<{
  type: z.ZodEnum<{
    interface: "interface";
    display: "display";
    layout: "layout";
    module: "module";
    panel: "panel";
    theme: "theme";
  }>;
  path: z.ZodString;
  source: z.ZodString;
}, z.core.$strip>, z.ZodObject<{
  type: z.ZodEnum<{
    hook: "hook";
    endpoint: "endpoint";
  }>;
  path: z.ZodString;
  source: z.ZodString;
  sandbox: z.ZodOptional<z.ZodObject<{
    enabled: z.ZodBoolean;
    requestedScopes: z.ZodObject<{
      request: z.ZodOptional<z.ZodObject<{
        urls: z.ZodArray<z.ZodString>;
        methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
      }, z.core.$strip>>;
      log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
      sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
    }, z.core.$strip>;
  }, z.core.$strip>>;
}, z.core.$strip>, z.ZodObject<{
  type: z.ZodEnum<{
    operation: "operation";
  }>;
  path: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
  source: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
  sandbox: z.ZodOptional<z.ZodObject<{
    enabled: z.ZodBoolean;
    requestedScopes: z.ZodObject<{
      request: z.ZodOptional<z.ZodObject<{
        urls: z.ZodArray<z.ZodString>;
        methods: z.ZodArray<z.ZodUnion<readonly [z.ZodLiteral<"GET">, z.ZodLiteral<"POST">, z.ZodLiteral<"PATCH">, z.ZodLiteral<"PUT">, z.ZodLiteral<"DELETE">]>>;
      }, z.core.$strip>>;
      log: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
      sleep: z.ZodOptional<z.ZodObject<{}, z.core.$strip>>;
    }, z.core.$strip>;
  }, z.core.$strip>>;
}, z.core.$strip>, z.ZodObject<{
  type: z.ZodLiteral<"bundle">;
  partial: z.ZodOptional<z.ZodBoolean>;
  path: z.ZodObject<{
    app: z.ZodString;
    api: z.ZodString;
  }, z.core.$strip>;
  entries: z.ZodArray<z.ZodUnion<readonly [z.ZodObject<{
    type: z.ZodEnum<{
      hook: "hook";
      endpoint: "endpoint";
    }>;
    name: z.ZodString;
    source: z.ZodString;
  }, z.core.$strip>, z.ZodObject<{
    type: z.ZodEnum<{
      interface: "interface";
      display: "display";
      layout: "layout";
      module: "module";
      panel: "panel";
      theme: "theme";
    }>;
    name: z.ZodString;
    source: z.ZodString;
  }, z.core.$strip>, z.ZodObject<{
    type: z.ZodEnum<{
      operation: "operation";
    }>;
    name: z.ZodString;
    source: z.ZodObject<{
      app: z.ZodString;
      api: z.ZodString;
    }, z.core.$strip>;
  }, z.core.$strip>]>>;
}, z.core.$strip>]>>;
type ExtensionOptions = z.infer<typeof ExtensionOptions>;
//#endregion
//#region src/node/utils/get-extensions.d.ts
declare function getExtensionDefinition(manifest: ExtensionManifest, meta: {
  path: string;
  local: boolean;
}): Extension;
declare function resolveFsExtensions(root: string): Promise<Map<string, Extension>>;
declare function resolveModuleExtensions(root: string): Promise<Map<string, Extension>>;
//#endregion
//#region src/shared/constants/languages.d.ts
declare const EXTENSION_LANGUAGES: readonly ["javascript", "typescript"];
//#endregion
//#region src/shared/constants/pkg-key.d.ts
declare const EXTENSION_PKG_KEY = "directus:extension";
//#endregion
//#region src/shared/constants/shared-deps.d.ts
/**
 * Dependencies that we guarantee are available in the global scope of the app's bundle when app
 * extensions are used. These are virtually rewritten to use the existing bundled instances in the
 * global scope rather than local copies
 */
declare const APP_SHARED_DEPS: readonly ["@directus/extensions-sdk", "vue", "vue-router", "vue-i18n", "pinia"];
/**
 * Dependencies that we guarantee are available in the node_modules of the API when API extensions
 * are used. The `directus:*` extensions are virtual entrypoints available in the sandbox
 */
declare const API_SHARED_DEPS: readonly ["directus", "directus:api"];
//#endregion
//#region src/shared/utils/define-extension.d.ts
type CustomConfig<T extends object> = { [K in string]: K extends keyof T ? never : unknown };
type ExtendedConfig<T extends object, C> = Prettify<T & Omit<C, keyof T>>;
declare function defineInterface<Custom extends CustomConfig<InterfaceConfig>>(config: ExtendedConfig<InterfaceConfig, Custom>): ExtendedConfig<InterfaceConfig, Custom>;
declare function defineDisplay<Custom extends CustomConfig<DisplayConfig>>(config: ExtendedConfig<DisplayConfig, Custom>): ExtendedConfig<DisplayConfig, Custom>;
declare function defineLayout<Options = any, Query = any>(config: LayoutConfig<Options, Query>): LayoutConfig<Options, Query>;
declare function defineModule<Custom extends CustomConfig<ModuleConfig>>(config: ExtendedConfig<ModuleConfig, Custom>): ExtendedConfig<ModuleConfig, Custom>;
declare function definePanel<Custom extends CustomConfig<PanelConfig>>(config: ExtendedConfig<PanelConfig, Custom>): ExtendedConfig<PanelConfig, Custom>;
declare function defineHook(config: HookConfig): HookConfig;
declare function defineEndpoint(config: EndpointConfig): EndpointConfig;
declare function defineOperationApp<Custom extends CustomConfig<OperationAppConfig>>(config: ExtendedConfig<OperationAppConfig, Custom>): ExtendedConfig<OperationAppConfig, Custom>;
declare function defineOperationApi<Options = Record<string, unknown>>(config: OperationApiConfig<Options>): OperationApiConfig<Options>;
//#endregion
export { API_EXTENSION_TYPES, API_SHARED_DEPS, APP_EXTENSION_TYPES, APP_OR_HYBRID_EXTENSION_PACKAGE_TYPES, APP_OR_HYBRID_EXTENSION_TYPES, APP_SHARED_DEPS, type ApiExtension, type ApiExtensionContext, type ApiExtensionType, type ApiOutput, type AppExtension, type AppExtensionConfigs, type AppExtensionType, type AppField, BUNDLE_EXTENSION_TYPES, type BundleExtension, type BundleExtensionEntry, type BundleExtensionType, type DisplayConfig, type DisplayFieldsFunction, EXTENSION_LANGUAGES, EXTENSION_PKG_KEY, EXTENSION_TYPES, type EndpointConfig, type EndpointExtensionContext, type Extension, ExtensionManifest, ExtensionOptions, ExtensionOptionsApi, ExtensionOptionsApp, ExtensionOptionsBase, ExtensionOptionsBundle, ExtensionOptionsBundleEntries, ExtensionOptionsBundleEntry, type ExtensionOptionsContext, ExtensionOptionsHybrid, ExtensionSandboxOptions, ExtensionSandboxRequestedScopes, type ExtensionSettings, type ExtensionType, HYBRID_EXTENSION_TYPES, type HookConfig, type HookExtensionContext, type HybridExtension, type HybridExtensionType, type InterfaceConfig, type LayoutConfig, type LayoutProps, type LayoutState, type ModuleConfig, NESTED_EXTENSION_TYPES, type NestedExtensionType, type OperationApiConfig, type OperationAppConfig, type OperationContext, type OperationHandler, type Panel, type PanelConfig, type PanelQuery, type RegisterFunctions, type ShowSelect, SplitEntrypoint, defineDisplay, defineEndpoint, defineHook, defineInterface, defineLayout, defineModule, defineOperationApi, defineOperationApp, definePanel, generateExtensionsEntrypoint, getExtensionDefinition, resolveFsExtensions, resolveModuleExtensions };