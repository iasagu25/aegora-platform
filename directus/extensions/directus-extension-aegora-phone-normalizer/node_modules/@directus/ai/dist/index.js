//#region src/models.ts
const DEFAULT_AI_MODELS = [
	{
		provider: "openai",
		model: "gpt-4o-mini",
		name: "GPT-4o Mini",
		limit: {
			context: 128e3,
			output: 16384
		},
		cost: {
			input: .15,
			output: .6
		},
		attachment: true,
		reasoning: false
	},
	{
		provider: "openai",
		model: "gpt-4.1-nano",
		name: "GPT-4.1 Nano",
		limit: {
			context: 1047576,
			output: 32768
		},
		cost: {
			input: .1,
			output: .4
		},
		attachment: true,
		reasoning: false
	},
	{
		provider: "openai",
		model: "gpt-4.1-mini",
		name: "GPT-4.1 Mini",
		limit: {
			context: 1047576,
			output: 32768
		},
		cost: {
			input: .4,
			output: 1.6
		},
		attachment: true,
		reasoning: false
	},
	{
		provider: "openai",
		model: "gpt-4.1",
		name: "GPT-4.1",
		limit: {
			context: 1047576,
			output: 32768
		},
		cost: {
			input: 2,
			output: 8
		},
		attachment: true,
		reasoning: false
	},
	{
		provider: "openai",
		model: "gpt-5-nano",
		name: "GPT-5 Nano",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: .05,
			output: .4
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5-mini",
		name: "GPT-5 Mini",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: .25,
			output: 2
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5",
		name: "GPT-5",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: 1.25,
			output: 10
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.1",
		name: "GPT-5.1",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: 1.25,
			output: 10
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.1-chat-latest",
		name: "GPT-5.1 Chat",
		limit: {
			context: 128e3,
			output: 16384
		},
		cost: {
			input: 1.25,
			output: 10
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.2",
		name: "GPT-5.2",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: 1.75,
			output: 14
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.2-chat-latest",
		name: "GPT-5.2 Chat",
		limit: {
			context: 128e3,
			output: 16384
		},
		cost: {
			input: 1.75,
			output: 14
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.2-pro",
		name: "GPT-5.2 Pro",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: 21,
			output: 168
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.4-nano",
		name: "GPT-5.4 Nano",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: .2,
			output: 1.25
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.4-mini",
		name: "GPT-5.4 Mini",
		limit: {
			context: 4e5,
			output: 128e3
		},
		cost: {
			input: .75,
			output: 4.5
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.4",
		name: "GPT-5.4",
		limit: {
			context: 105e4,
			output: 128e3
		},
		cost: {
			input: 2.5,
			output: 15
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.4-pro",
		name: "GPT-5.4 Pro",
		limit: {
			context: 105e4,
			output: 128e3
		},
		cost: {
			input: 30,
			output: 180
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.5",
		name: "GPT-5.5",
		limit: {
			context: 105e4,
			output: 128e3
		},
		cost: {
			input: 5,
			output: 30
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "openai",
		model: "gpt-5.5-pro",
		name: "GPT-5.5 Pro",
		limit: {
			context: 105e4,
			output: 128e3
		},
		cost: {
			input: 30,
			output: 180
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "anthropic",
		model: "claude-haiku-4-5",
		name: "Claude Haiku 4.5",
		limit: {
			context: 2e5,
			output: 64e3
		},
		cost: {
			input: 1,
			output: 5
		},
		attachment: true,
		reasoning: false
	},
	{
		provider: "anthropic",
		model: "claude-sonnet-4-6",
		name: "Claude Sonnet 4.6",
		limit: {
			context: 2e5,
			output: 64e3
		},
		cost: {
			input: 3,
			output: 15
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "anthropic",
		model: "claude-opus-4-7",
		name: "Claude Opus 4.7",
		limit: {
			context: 2e5,
			output: 128e3
		},
		cost: {
			input: 5,
			output: 25
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "anthropic",
		model: "claude-opus-4-6",
		name: "Claude Opus 4.6",
		limit: {
			context: 2e5,
			output: 128e3
		},
		cost: {
			input: 5,
			output: 25
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "google",
		model: "gemini-3.1-pro-preview",
		name: "Gemini 3.1 Pro Preview",
		limit: {
			context: 1048576,
			output: 65536
		},
		cost: {
			input: 2,
			output: 12
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "google",
		model: "gemini-3.1-flash-lite-preview",
		name: "Gemini 3.1 Flash Lite Preview",
		limit: {
			context: 1048576,
			output: 65536
		},
		cost: {
			input: .5,
			output: 3
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "google",
		model: "gemini-3-pro-preview",
		name: "Gemini 3 Pro Preview",
		limit: {
			context: 1048576,
			output: 65536
		},
		cost: {
			input: 2,
			output: 12
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "google",
		model: "gemini-3-flash-preview",
		name: "Gemini 3 Flash Preview",
		limit: {
			context: 1048576,
			output: 65536
		},
		cost: {
			input: .5,
			output: 3
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "google",
		model: "gemini-2.5-pro",
		name: "Gemini 2.5 Pro",
		limit: {
			context: 1048576,
			output: 65536
		},
		cost: {
			input: 1.25,
			output: 10
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "google",
		model: "gemini-2.5-flash",
		name: "Gemini 2.5 Flash",
		limit: {
			context: 1048576,
			output: 65536
		},
		cost: {
			input: .3,
			output: 2.5
		},
		attachment: true,
		reasoning: true
	},
	{
		provider: "google",
		model: "gemini-2.5-flash-lite",
		name: "Gemini 2.5 Flash Lite",
		limit: {
			context: 1048576,
			output: 65536
		},
		cost: {
			input: .1,
			output: .4
		},
		attachment: true,
		reasoning: true
	}
];
function buildCustomModels(customModels) {
	if (!customModels) return [];
	return customModels.map((m) => ({
		provider: "openai-compatible",
		model: m.id,
		name: m.name,
		limit: {
			context: m.context ?? 128e3,
			output: m.output ?? 16e3
		},
		cost: {
			input: 0,
			output: 0
		},
		attachment: m.attachment ?? false,
		reasoning: m.reasoning ?? false
	}));
}
function buildCustomModelDefinition(provider, modelId) {
	return {
		provider,
		model: modelId,
		name: modelId,
		limit: {
			context: 128e3,
			output: 16e3
		},
		cost: {
			input: 0,
			output: 0
		},
		attachment: false,
		reasoning: false
	};
}

//#endregion
//#region src/files.ts
const AI_ALLOWED_MIME_TYPES = [
	"image/jpeg",
	"image/png",
	"image/gif",
	"image/webp",
	"application/pdf",
	"text/plain",
	"audio/mpeg",
	"audio/wav",
	"video/mp4"
];

//#endregion
export { AI_ALLOWED_MIME_TYPES, DEFAULT_AI_MODELS, buildCustomModelDefinition, buildCustomModels };