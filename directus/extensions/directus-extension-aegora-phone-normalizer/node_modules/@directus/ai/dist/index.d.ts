//#region src/types.d.ts
type ProviderType = "openai" | "anthropic" | "google" | "openai-compatible";
type StandardProviderType = Exclude<ProviderType, "openai-compatible">;
type JSONValue = string | number | boolean | null | JSONValue[] | {
  [key: string]: JSONValue;
};
type ToolApprovalMode = "always" | "ask" | "disabled";
type SystemTool = "items" | "files" | "folders" | "assets" | "flows" | "trigger-flow" | "operations" | "schema" | "collections" | "fields" | "relations";
interface OpenAICompatibleModel {
  id: string;
  name: string;
  context?: number;
  output?: number;
  attachment?: boolean;
  reasoning?: boolean;
  providerOptions?: {
    [key: string]: JSONValue;
  };
}
interface OpenAICompatibleHeader {
  header: string;
  value: string;
}
interface ModelDefinition {
  provider: ProviderType;
  model: string;
  name: string;
  limit: {
    context: number;
    output: number;
  };
  cost: {
    input: number;
    output: number;
  };
  /** Supports file attachments */
  attachment: boolean;
  /** Supports reasoning / chain-of-thought */
  reasoning: boolean;
}
type PrimaryKey = string | number;
interface ItemContextData {
  collection: string;
  key: PrimaryKey;
}
interface VisualElementContextData {
  key: string;
  collection: string;
  item: PrimaryKey;
  fields?: string[];
  rect?: {
    top: number;
    left: number;
    width: number;
    height: number;
  };
}
interface PromptContextData {
  text: string;
  prompt: Record<string, unknown>;
  values: Record<string, string>;
}
type ContextAttachment = {
  type: "item";
  data: ItemContextData;
  display: string;
  snapshot: Record<string, unknown>;
} | {
  type: "visual-element";
  data: VisualElementContextData;
  display: string;
  snapshot: Record<string, unknown>;
} | {
  type: "prompt";
  data: PromptContextData;
  display: string;
  snapshot: Record<string, unknown>;
};
interface ProviderFileRef {
  provider: StandardProviderType;
  fileId: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  expiresAt: string | null;
}
//#endregion
//#region src/models.d.ts
declare const DEFAULT_AI_MODELS: ModelDefinition[];
declare function buildCustomModels(customModels: OpenAICompatibleModel[] | null): ModelDefinition[];
declare function buildCustomModelDefinition(provider: ProviderType, modelId: string): ModelDefinition;
//#endregion
//#region src/files.d.ts
declare const AI_ALLOWED_MIME_TYPES: readonly ["image/jpeg", "image/png", "image/gif", "image/webp", "application/pdf", "text/plain", "audio/mpeg", "audio/wav", "video/mp4"];
type AiAllowedMimeType = (typeof AI_ALLOWED_MIME_TYPES)[number];
//#endregion
export { AI_ALLOWED_MIME_TYPES, AiAllowedMimeType, ContextAttachment, DEFAULT_AI_MODELS, ItemContextData, JSONValue, ModelDefinition, OpenAICompatibleHeader, OpenAICompatibleModel, PrimaryKey, PromptContextData, ProviderFileRef, ProviderType, StandardProviderType, SystemTool, ToolApprovalMode, VisualElementContextData, buildCustomModelDefinition, buildCustomModels };