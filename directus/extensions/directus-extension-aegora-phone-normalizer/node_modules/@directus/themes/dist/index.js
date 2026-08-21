import { Teleport, computed, createBlock, createTextVNode, defineComponent, openBlock, reactive, toDisplayString, toRefs, unref } from "vue";
import { useHead } from "@unhead/vue";
import z$1, { ZodObject, ZodOptional, ZodString, ZodUnion, z } from "zod";
import { cssVar } from "@directus/utils/browser";
import { get, mapKeys, merge } from "lodash-es";
import { defineStore, storeToRefs } from "pinia";
import decamelize from "decamelize";
import { flatten } from "flat";

//#region ../types/dist/index.js
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
const Color = z.string();
const FamilyName = z.string().meta({ $ref: "FamilyName" });
const FontWeight = z.string().meta({ $ref: "FontWeight" });
const Length = z.string();
const Percentage = z.string();
const BoxShadow = z.string();
const Number$1 = z.string();
const Size = z.string();
const LineWidth = z.union([
	z.string(),
	z.literal("thin"),
	z.literal("medium"),
	z.literal("thick")
]);
const FormRules = z.object({
	columnGap: z.union([Length, Percentage]).optional(),
	rowGap: z.union([Length, Percentage]).optional(),
	field: z.object({
		label: z.object({
			foreground: Color.optional(),
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		input: z.object({
			background: Color.optional(),
			backgroundSubdued: Color.optional(),
			foreground: Color.optional(),
			foregroundSubdued: Color.optional(),
			borderColor: Color.optional(),
			borderColorHover: Color.optional(),
			focusRingColor: Color.optional(),
			boxShadow: BoxShadow.optional(),
			height: Size.optional(),
			padding: z.union([Length, Percentage]).optional()
		}).optional()
	}).optional()
}).optional();
const Rules = z.object({
	borderRadius: z.union([Length, Percentage]).optional(),
	borderWidth: LineWidth.optional(),
	foreground: Color.optional(),
	foregroundSubdued: Color.optional(),
	foregroundAccent: Color.optional(),
	background: Color.optional(),
	backgroundNormal: Color.optional(),
	backgroundAccent: Color.optional(),
	backgroundSubdued: Color.optional(),
	borderColor: Color.optional(),
	borderColorAccent: Color.optional(),
	borderColorSubdued: Color.optional(),
	primary: Color.optional(),
	primaryBackground: Color.optional(),
	primarySubdued: Color.optional(),
	primaryAccent: Color.optional(),
	secondary: Color.optional(),
	secondaryBackground: Color.optional(),
	secondarySubdued: Color.optional(),
	secondaryAccent: Color.optional(),
	success: Color.optional(),
	successBackground: Color.optional(),
	successSubdued: Color.optional(),
	successAccent: Color.optional(),
	warning: Color.optional(),
	warningBackground: Color.optional(),
	warningSubdued: Color.optional(),
	warningAccent: Color.optional(),
	danger: Color.optional(),
	dangerBackground: Color.optional(),
	dangerSubdued: Color.optional(),
	dangerAccent: Color.optional(),
	fonts: z.object({
		display: z.object({
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		title: z.object({
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		sans: z.object({
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		serif: z.object({
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		monospace: z.object({
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional()
	}).optional(),
	shell: z.object({
		background: Color.optional(),
		backgroundAccent: Color.optional(),
		borderWidth: LineWidth.optional(),
		borderColor: Color.optional()
	}).optional(),
	navigation: z.object({
		project: z.object({
			foreground: Color.optional(),
			fontFamily: FamilyName.optional()
		}).optional(),
		modules: z.object({
			background: Color.optional(),
			borderWidth: LineWidth.optional(),
			borderColor: Color.optional(),
			button: z.object({
				foreground: Color.optional(),
				foregroundHover: Color.optional(),
				foregroundActive: Color.optional(),
				background: Color.optional(),
				backgroundHover: Color.optional(),
				backgroundActive: Color.optional()
			}).optional()
		}).optional(),
		list: z.object({
			icon: z.object({
				foreground: Color.optional(),
				foregroundHover: Color.optional(),
				foregroundActive: Color.optional()
			}).optional(),
			foreground: Color.optional(),
			foregroundHover: Color.optional(),
			foregroundActive: Color.optional(),
			background: Color.optional(),
			backgroundHover: Color.optional(),
			backgroundActive: Color.optional(),
			fontFamily: FamilyName.optional(),
			divider: z.object({
				borderColor: Color.optional(),
				borderWidth: LineWidth.optional()
			})
		}).optional()
	}).optional(),
	header: z.object({ title: z.object({
		foreground: Color.optional(),
		fontFamily: FamilyName.optional(),
		fontWeight: FontWeight.optional()
	}).optional() }).optional(),
	form: FormRules,
	sidebar: z.object({
		background: Color.optional(),
		foreground: Color.optional(),
		fontFamily: FamilyName.optional(),
		borderWidth: LineWidth.optional(),
		borderColor: Color.optional(),
		section: z.object({
			borderWidth: LineWidth.optional(),
			borderColor: Color.optional(),
			active: z.object({
				borderWidth: LineWidth.optional(),
				borderColor: Color.optional()
			}).optional(),
			toggle: z.object({
				icon: z.object({
					foreground: Color.optional(),
					foregroundHover: Color.optional(),
					foregroundActive: Color.optional()
				}).optional(),
				foreground: Color.optional(),
				foregroundHover: Color.optional(),
				foregroundActive: Color.optional(),
				background: Color.optional(),
				backgroundHover: Color.optional(),
				backgroundActive: Color.optional(),
				fontFamily: FamilyName.optional()
			}).optional(),
			form: FormRules
		}).optional()
	}).optional(),
	public: z.object({
		background: Color.optional(),
		foreground: Color.optional(),
		foregroundAccent: Color.optional(),
		art: z.object({
			background: Color.optional(),
			primary: Color.optional(),
			secondary: Color.optional(),
			speed: Number$1.optional()
		}).optional(),
		form: FormRules
	}).optional(),
	popover: z.object({ menu: z.object({
		background: Color.optional(),
		borderRadius: z.union([Length, Percentage]).optional(),
		boxShadow: BoxShadow.optional()
	}).optional() }).optional(),
	banner: z.object({
		background: Color.optional(),
		padding: z.union([Length, Percentage]).optional(),
		borderRadius: z.union([Length, Percentage]).optional(),
		avatar: z.object({
			background: Color.optional(),
			foreground: Color.optional(),
			borderRadius: z.union([Length, Percentage]).optional()
		}).optional(),
		headline: z.object({
			foreground: Color.optional(),
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		title: z.object({
			foreground: Color.optional(),
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		subtitle: z.object({
			foreground: Color.optional(),
			fontFamily: FamilyName.optional(),
			fontWeight: FontWeight.optional()
		}).optional(),
		art: z.object({ foreground: Color.optional() }).optional()
	}).optional()
});
const ThemeSchema = z.object({
	id: z.string(),
	name: z.string(),
	appearance: z.union([z.literal("light"), z.literal("dark")]),
	rules: Rules
});
const zodStringOrNumber = z.union([z.string(), z.number()]);
const WebSocketMessage = z.object({
	type: z.string(),
	uid: zodStringOrNumber.optional()
}).passthrough();
const TYPE = { COLLAB: "collab" };
const COLORS = [
	"purple",
	"pink",
	"blue",
	"green",
	"yellow",
	"orange",
	"red"
];
const ACTION = {
	CLIENT: {
		JOIN: "join",
		LEAVE: "leave",
		UPDATE: "update",
		UPDATE_ALL: "updateAll",
		FOCUS: "focus",
		DISCARD: "discard"
	},
	SERVER: {
		INIT: "init",
		JOIN: "join",
		LEAVE: "leave",
		SAVE: "save",
		DELETE: "delete",
		UPDATE: "update",
		FOCUS: "focus",
		DISCARD: "discard",
		ERROR: "error"
	}
};
const BaseClientMessage = z$1.object({
	type: z$1.literal(TYPE.COLLAB),
	room: z$1.string()
});
const ClientMessage = z$1.discriminatedUnion("action", [
	z$1.object({
		type: z$1.literal(TYPE.COLLAB),
		action: z$1.literal(ACTION.CLIENT.JOIN),
		collection: z$1.string(),
		item: z$1.union([z$1.string(), z$1.number()]).nullable(),
		version: z$1.string().nullable(),
		color: z$1.enum(COLORS).nullable().optional(),
		initialChanges: z$1.record(z$1.string(), z$1.any()).optional()
	}),
	BaseClientMessage.extend({ action: z$1.literal(ACTION.CLIENT.LEAVE) }),
	BaseClientMessage.extend({
		action: z$1.literal(ACTION.CLIENT.UPDATE),
		field: z$1.string(),
		changes: z$1.unknown().optional()
	}),
	BaseClientMessage.extend({
		action: z$1.literal(ACTION.CLIENT.UPDATE_ALL),
		changes: z$1.record(z$1.string(), z$1.any()).optional()
	}),
	BaseClientMessage.extend({
		action: z$1.literal(ACTION.CLIENT.FOCUS),
		field: z$1.string().nullable()
	}),
	BaseClientMessage.extend({ action: z$1.literal(ACTION.CLIENT.DISCARD) })
]);

//#endregion
//#region src/composables/use-fonts.ts
const useFonts = (theme) => {
	const paths = computed(() => {
		const paths$1 = /* @__PURE__ */ new Map();
		const find = (schema, path = []) => {
			if (schema instanceof ZodObject) for (const [key, value] of Object.entries(schema.shape)) find(value, [...path, key]);
			else if (schema instanceof ZodOptional) find(schema.def.innerType, path);
			else if (schema instanceof ZodUnion) for (const option of schema.options) find(option, path);
			else if (schema instanceof ZodString) {
				const parentPath = path.slice(0, -1).join(".");
				const key = path.at(-1);
				if (schema.meta()?.["$ref"] === "FamilyName") if (paths$1.has(parentPath)) paths$1.set(parentPath, {
					family: key,
					weight: paths$1.get(parentPath).weight
				});
				else paths$1.set(parentPath, {
					family: key,
					weight: null
				});
				else if (schema.meta()?.["$ref"] === "FontWeight") if (paths$1.has(parentPath)) paths$1.set(parentPath, {
					family: paths$1.get(parentPath).family,
					weight: key
				});
				else paths$1.set(parentPath, {
					family: null,
					weight: key
				});
			}
		};
		find(ThemeSchema.shape.rules);
		return paths$1;
	});
	const fonts = computed(() => {
		/** [family, weight] */
		const defs = /* @__PURE__ */ new Map();
		for (const [path, { family, weight }] of paths.value.entries()) {
			let familyDefinition = null;
			let weightDefinition = null;
			const pathParts = path.split(".");
			if (family) familyDefinition = get(unref(theme).rules, [...pathParts, family]);
			if (weight) weightDefinition = get(unref(theme).rules, [...pathParts, weight]);
			if (familyDefinition) {
				const stack = familyDefinition.split(",");
				for (const def of stack) {
					const trimmed = def.trim();
					if (trimmed.startsWith("var(--")) {
						stack.push(cssVar(trimmed.slice(6, -1)));
						continue;
					}
					if ((trimmed.startsWith("\"") && trimmed.endsWith("\"")) === false) continue;
					const noQuotes = trimmed.slice(1, -1);
					if (defs.has(noQuotes)) defs.get(noQuotes).add(weightDefinition ?? "400");
					else defs.set(noQuotes, new Set([weightDefinition ?? "400"]));
				}
			}
		}
		return defs;
	});
	return { googleFonts: computed(() => {
		const families = [];
		for (const [family, weights] of fonts.value.entries()) if ([
			"Inter",
			"Merriweather",
			"Fira Mono"
		].includes(family) === false) {
			const weightsParam = Array.from(weights).sort((a, b) => Number(a) - Number(b)).join(";");
			families.push(`${family.replaceAll(" ", "+")}:wght@${weightsParam}`);
		}
		return families;
	}) };
};

//#endregion
//#region src/utils/define-theme.ts
const defineTheme = (theme) => theme;

//#endregion
//#region src/themes/dark/default.ts
var default_default = defineTheme({
	id: "Directus Default",
	name: "$t:theme_directus_default",
	appearance: "dark",
	rules: {
		borderRadius: "0.375rem",
		borderWidth: "1px",
		foreground: "#c9d1d9",
		foregroundAccent: "#f0f6fc",
		foregroundSubdued: "#666672",
		background: "#0d1117",
		backgroundNormal: "#21262e",
		backgroundAccent: "#30363d",
		backgroundSubdued: "#161b22",
		borderColor: "#21262e",
		borderColorAccent: "#30363d",
		borderColorSubdued: "#21262d",
		primary: "var(--project-color)",
		primaryBackground: "color-mix(in srgb, var(--theme--background), var(--theme--primary) 10%)",
		primarySubdued: "color-mix(in srgb, var(--theme--background), var(--theme--primary) 50%)",
		primaryAccent: "color-mix(in srgb, var(--theme--primary), #16151a 25%)",
		secondary: "#ff99dd",
		secondaryBackground: "color-mix(in srgb, var(--theme--background), var(--theme--secondary) 10%)",
		secondarySubdued: "color-mix(in srgb, var(--theme--background), var(--theme--secondary) 50%)",
		secondaryAccent: "color-mix(in srgb, var(--theme--secondary), #16151a 25%)",
		success: "#2ecda7",
		successBackground: "color-mix(in srgb, var(--theme--background), var(--theme--success) 10%)",
		successSubdued: "color-mix(in srgb, var(--theme--background), var(--theme--success) 50%)",
		successAccent: "color-mix(in srgb, var(--theme--success), #16151a 25%)",
		warning: "#ffa439",
		warningBackground: "color-mix(in srgb, var(--theme--background), var(--theme--warning) 10%)",
		warningSubdued: "color-mix(in srgb, var(--theme--background), var(--theme--warning) 50%)",
		warningAccent: "color-mix(in srgb, var(--theme--warning), #16151a 25%)",
		danger: "#e35169",
		dangerBackground: "color-mix(in srgb, var(--theme--background), var(--theme--danger) 10%)",
		dangerSubdued: "color-mix(in srgb, var(--theme--background), var(--theme--danger) 50%)",
		dangerAccent: "color-mix(in srgb, var(--theme--danger), #16151a 25%)",
		fonts: {
			display: {
				fontFamily: "\"Inter\", system-ui",
				fontWeight: "700"
			},
			title: {
				fontFamily: "\"Inter\", system-ui",
				fontWeight: "600"
			},
			sans: {
				fontFamily: "\"Inter\", system-ui",
				fontWeight: "500"
			},
			serif: {
				fontFamily: "\"Merriweather\", serif",
				fontWeight: "500"
			},
			monospace: {
				fontFamily: "\"Fira Mono\", monospace",
				fontWeight: "500"
			}
		},
		shell: {
			background: "var(--theme--background-subdued)",
			backgroundAccent: "#30363d",
			borderColor: "var(--theme--border-color)",
			borderWidth: "var(--theme--border-width)"
		},
		navigation: {
			project: {
				foreground: "var(--theme--foreground-accent)",
				fontFamily: "var(--theme--fonts--sans--font-family)"
			},
			modules: {
				background: "var(--theme--background)",
				borderColor: "transparent",
				borderWidth: "0px",
				button: {
					foreground: "var(--theme--foreground-subdued)",
					foregroundHover: "#fff",
					foregroundActive: "var(--theme--foreground-accent)",
					background: "transparent",
					backgroundHover: "transparent",
					backgroundActive: "#21262e"
				}
			},
			list: {
				icon: {
					foreground: "var(--theme--primary)",
					foregroundHover: "var(--theme--navigation--list--icon--foreground)",
					foregroundActive: "var(--theme--navigation--list--icon--foreground)"
				},
				foreground: "var(--theme--foreground-accent)",
				foregroundHover: "var(--theme--navigation--list--foreground)",
				foregroundActive: "var(--theme--navigation--list--foreground)",
				background: "transparent",
				backgroundHover: "#30363d",
				backgroundActive: "#30363d",
				fontFamily: "var(--theme--fonts--sans--font-family)",
				divider: {
					borderColor: "#30363d",
					borderWidth: "var(--theme--border-width)"
				}
			}
		},
		header: { title: {
			foreground: "var(--theme--foreground)",
			fontFamily: "var(--theme--fonts--title--font-family)",
			fontWeight: "var(--theme--fonts--title--font-weight)"
		} },
		form: {
			columnGap: "1.75rem",
			rowGap: "2.25rem",
			field: {
				label: {
					foreground: "var(--theme--foreground-accent)",
					fontFamily: "var(--theme--fonts--sans--font-family)",
					fontWeight: "600"
				},
				input: {
					background: "var(--theme--background)",
					backgroundSubdued: "var(--theme--background-subdued)",
					foreground: "var(--theme--foreground)",
					foregroundSubdued: "var(--theme--foreground-subdued)",
					borderColor: "#21262e",
					borderColorHover: "#30363d",
					focusRingColor: "var(--theme--primary)",
					boxShadow: "none",
					height: "3.375rem",
					padding: "0.875rem"
				}
			}
		},
		sidebar: {
			background: "var(--theme--background)",
			foreground: "var(--theme--foreground)",
			fontFamily: "var(--theme--fonts--sans--font-family)",
			borderColor: "var(--theme--border-color)",
			borderWidth: "var(--theme--border-width)",
			section: {
				borderWidth: "var(--theme--sidebar--border-width)",
				borderColor: "transparent",
				active: {
					borderWidth: "var(--theme--sidebar--section--border-width)",
					borderColor: "var(--theme--sidebar--border-color)"
				},
				toggle: {
					icon: {
						foreground: "var(--theme--sidebar--foreground)",
						foregroundHover: "var(--theme--sidebar--section--toggle--foreground-hover)",
						foregroundActive: "var(--theme--sidebar--section--toggle--foreground-active)"
					},
					foreground: "var(--theme--sidebar--foreground)",
					foregroundHover: "var(--theme--foreground-accent)",
					foregroundActive: "var(--theme--sidebar--section--toggle--foreground)",
					background: "var(--theme--sidebar--background)",
					backgroundHover: "var(--theme--sidebar--section--toggle--background)",
					backgroundActive: "var(--theme--sidebar--section--toggle--background)",
					fontFamily: "var(--theme--fonts--sans--font-family)"
				},
				form: {
					columnGap: "var(--theme--form--column-gap)",
					rowGap: "var(--theme--form--row-gap)",
					label: {
						foreground: "var(--theme--form--field--label--foreground)",
						fontFamily: "var(--theme--form--field--label--font-family)"
					},
					field: { input: {
						background: "var(--theme--form--field--input--background)",
						foreground: "var(--theme--form--field--input--foreground)",
						foregroundSubdued: "var(--theme--form--field--input--foreground-subdued)",
						borderColor: "var(--theme--form--field--input--border-color)",
						borderColorHover: "var(--theme--form--field--input--border-color-hover)",
						focusRingColor: "var(--theme--form--field--input--focus-ring-color)",
						boxShadow: "var(--theme--form--field--input--box-shadow)",
						height: "2.9375rem",
						padding: "0.6875rem"
					} }
				}
			}
		},
		public: {
			background: "var(--theme--background)",
			foreground: "var(--theme--foreground)",
			foregroundAccent: "var(--theme--foreground-accent)",
			art: {
				background: "#0e1c2f",
				primary: "var(--theme--primary)",
				secondary: "var(--theme--secondary)",
				speed: "1"
			},
			form: {
				columnGap: "var(--theme--form--column-gap)",
				rowGap: "var(--theme--form--row-gap)",
				field: {
					label: {
						foreground: "var(--theme--form--field--label--foreground)",
						fontFamily: "var(--theme--form--field--label--font-family)"
					},
					input: {
						background: "var(--theme--form--field--input--background)",
						foreground: "var(--theme--form--field--input--foreground)",
						foregroundSubdued: "var(--theme--form--field--input--foreground-subdued)",
						borderColor: "var(--theme--form--field--input--border-color)",
						borderColorHover: "var(--theme--form--field--input--border-color-hover)",
						focusRingColor: "var(--theme--form--field--input--focus-ring-color)",
						boxShadow: "var(--theme--form--field--input--box-shadow)",
						height: "var(--theme--form--field--input--height)",
						padding: "var(--theme--form--field--input--padding)"
					}
				}
			}
		},
		popover: { menu: {
			background: "#161b22",
			borderRadius: "var(--theme--border-radius)",
			boxShadow: "0px 0px 6px 0px black"
		} },
		banner: {
			background: "#0e1c2f",
			padding: "2.25rem",
			borderRadius: "var(--theme--border-radius)",
			avatar: {
				borderRadius: "50%",
				foreground: "var(--theme--primary)",
				background: "#ffffff"
			},
			headline: {
				foreground: "#ffffff",
				fontFamily: "var(--theme--fonts--sans--font-family)",
				fontWeight: "var(--theme--fonts--sans--font-weight)"
			},
			title: {
				foreground: "#ffffff",
				fontFamily: "var(--theme--fonts--display--font-family)",
				fontWeight: "var(--theme--fonts--display--font-weight)"
			},
			subtitle: {
				foreground: "#a2b5cd",
				fontFamily: "var(--theme--fonts--monospace--font-family)",
				fontWeight: "var(--theme--fonts--monospace--font-weight)"
			},
			art: { foreground: "#2e3a4d" }
		}
	}
});

//#endregion
//#region src/themes/light/color-match.ts
var color_match_default = defineTheme({
	id: "Directus Color Match",
	name: "$t:theme_directus_colormatch",
	appearance: "light",
	rules: {
		background: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 7%)",
		backgroundAccent: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 20%)",
		backgroundNormal: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 15%)",
		backgroundSubdued: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 10%)",
		borderColor: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 20%)",
		borderColorAccent: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 40%)",
		borderColorSubdued: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 15%)",
		borderRadius: "0.6875rem",
		borderWidth: "1px",
		foreground: "color-mix(in srgb, #000000, var(--theme--primary) 70%)",
		foregroundAccent: "color-mix(in srgb, #000000, var(--theme--primary) 50%)",
		foregroundSubdued: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 60%)",
		fonts: { display: {
			fontFamily: "\"Montserrat\", system-ui",
			fontWeight: "400"
		} },
		form: { field: { input: {
			background: "#FFFFFF",
			backgroundSubdued: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 13%)"
		} } },
		shell: {
			background: "#FFFFFF",
			backgroundAccent: "var(--theme--background)",
			borderColor: "var(--theme--border-color-subdued)"
		},
		navigation: {
			modules: {
				background: "color-mix(in srgb, #000000, var(--theme--primary) 90%)",
				button: {
					backgroundActive: "#FFFFFF",
					foreground: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 20%)",
					foregroundActive: "var(--theme--primary)"
				}
			},
			project: {},
			list: {
				divider: { borderColor: "var(--theme--border-color-subdued)" },
				icon: { foreground: "var(--theme--foreground)" },
				foreground: "var(--theme--foreground)",
				foregroundHover: "var(--theme--foreground)",
				foregroundActive: "var(--theme--foreground)"
			}
		},
		public: {
			art: {
				background: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 10%)",
				primary: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 60%)",
				secondary: "color-mix(in srgb, #FFFFFF, var(--theme--secondary) 70%)"
			},
			background: "#FFFFFF"
		}
	}
});

//#endregion
//#region src/themes/light/default.ts
var default_default$1 = defineTheme({
	id: "Directus Default",
	name: "$t:theme_directus_default",
	appearance: "light",
	rules: {
		borderRadius: "0.375rem",
		borderWidth: "1px",
		foreground: "#4f5464",
		foregroundAccent: "#172940",
		foregroundSubdued: "#a2b5cd",
		background: "#fff",
		backgroundNormal: "#f0f4f9",
		backgroundAccent: "#e4eaf1",
		backgroundSubdued: "#f7fafc",
		borderColor: "#e4eaf1",
		borderColorAccent: "#d3dae4",
		borderColorSubdued: "#f0f4f9",
		primary: "var(--project-color)",
		primaryBackground: "color-mix(in srgb, var(--theme--background), var(--theme--primary) 10%)",
		primarySubdued: "color-mix(in srgb, var(--theme--background), var(--theme--primary) 50%)",
		primaryAccent: "color-mix(in srgb, var(--theme--primary), #2e3c43 25%)",
		secondary: "#ff99dd",
		secondaryBackground: "color-mix(in srgb, var(--theme--background), var(--theme--secondary) 10%)",
		secondarySubdued: "color-mix(in srgb, var(--theme--background), var(--theme--secondary) 50%)",
		secondaryAccent: "color-mix(in srgb, var(--theme--secondary), #2e3c43 25%)",
		success: "#2ecda7",
		successBackground: "color-mix(in srgb, var(--theme--background), var(--theme--success) 10%)",
		successSubdued: "color-mix(in srgb, var(--theme--background), var(--theme--success) 50%)",
		successAccent: "color-mix(in srgb, var(--theme--success), #2e3c43 25%)",
		warning: "#ffa439",
		warningBackground: "color-mix(in srgb, var(--theme--background), var(--theme--warning) 10%)",
		warningSubdued: "color-mix(in srgb, var(--theme--background), var(--theme--warning) 50%)",
		warningAccent: "color-mix(in srgb, var(--theme--warning), #2e3c43 25%)",
		danger: "#e35169",
		dangerBackground: "color-mix(in srgb, var(--theme--background), var(--theme--danger) 10%)",
		dangerSubdued: "color-mix(in srgb, var(--theme--background), var(--theme--danger) 50%)",
		dangerAccent: "color-mix(in srgb, var(--theme--danger), #2e3c43 25%)",
		fonts: {
			display: {
				fontFamily: "\"Inter\", system-ui",
				fontWeight: "700"
			},
			title: {
				fontFamily: "\"Inter\", system-ui",
				fontWeight: "600"
			},
			sans: {
				fontFamily: "\"Inter\", system-ui",
				fontWeight: "500"
			},
			serif: {
				fontFamily: "\"Merriweather\", serif",
				fontWeight: "500"
			},
			monospace: {
				fontFamily: "\"Fira Mono\", monospace",
				fontWeight: "500"
			}
		},
		shell: {
			background: "var(--theme--background-subdued)",
			backgroundAccent: "var(--theme--background-accent)",
			borderColor: "var(--theme--border-color)",
			borderWidth: "var(--theme--border-width)"
		},
		navigation: {
			project: {
				foreground: "var(--theme--foreground-accent)",
				fontFamily: "var(--theme--font-family-sans-serif)"
			},
			modules: {
				background: "#0e1c2f",
				borderColor: "transparent",
				borderWidth: "0px",
				button: {
					foreground: "#8196b1",
					foregroundHover: "#fff",
					foregroundActive: "var(--theme--foreground-accent)",
					background: "transparent",
					backgroundHover: "transparent",
					backgroundActive: "var(--theme--background-normal)"
				}
			},
			list: {
				icon: {
					foreground: "var(--theme--primary)",
					foregroundHover: "var(--theme--navigation--list--icon--foreground)",
					foregroundActive: "var(--theme--navigation--list--icon--foreground)"
				},
				foreground: "var(--theme--foreground-accent)",
				foregroundHover: "var(--theme--navigation--list--foreground)",
				foregroundActive: "var(--theme--navigation--list--foreground)",
				background: "transparent",
				backgroundHover: "var(--theme--shell--background-accent)",
				backgroundActive: "var(--theme--shell--background-accent)",
				fontFamily: "var(--theme--fonts--sans--font-family)",
				divider: {
					borderColor: "var(--theme--border-color-accent)",
					borderWidth: "var(--theme--border-width)"
				}
			}
		},
		header: { title: {
			foreground: "var(--theme--foreground)",
			fontFamily: "var(--theme--fonts--title--font-family)",
			fontWeight: "var(--theme--fonts--title--font-weight)"
		} },
		form: {
			columnGap: "1.75rem",
			rowGap: "2.25rem",
			field: {
				label: {
					foreground: "var(--theme--foreground-accent)",
					fontFamily: "var(--theme--fonts--sans--font-family)",
					fontWeight: "600"
				},
				input: {
					background: "var(--theme--background)",
					backgroundSubdued: "var(--theme--background-subdued)",
					foreground: "var(--theme--foreground)",
					foregroundSubdued: "var(--theme--foreground-subdued)",
					borderColor: "var(--theme--border-color)",
					borderColorHover: "var(--theme--border-color-accent)",
					focusRingColor: "var(--theme--primary)",
					boxShadow: "none",
					height: "3.375rem",
					padding: "0.875rem"
				}
			}
		},
		sidebar: {
			background: "var(--theme--background)",
			foreground: "var(--theme--foreground)",
			fontFamily: "var(--theme--fonts--sans--font-family)",
			borderColor: "var(--theme--border-color)",
			borderWidth: "var(--theme--border-width)",
			section: {
				borderWidth: "var(--theme--sidebar--border-width)",
				borderColor: "transparent",
				active: {
					borderWidth: "var(--theme--sidebar--section--border-width)",
					borderColor: "var(--theme--sidebar--border-color)"
				},
				toggle: {
					icon: {
						foreground: "var(--theme--sidebar--foreground)",
						foregroundHover: "var(--theme--sidebar--section--toggle--foreground-hover)",
						foregroundActive: "var(--theme--sidebar--section--toggle--foreground-active)"
					},
					foreground: "var(--theme--sidebar--foreground)",
					foregroundHover: "var(--theme--foreground-accent)",
					foregroundActive: "var(--theme--sidebar--section--toggle--foreground)",
					background: "var(--theme--sidebar--background)",
					backgroundHover: "var(--theme--sidebar--section--toggle--background)",
					backgroundActive: "var(--theme--sidebar--section--toggle--background)",
					fontFamily: "var(--theme--fonts--sans--font-family)"
				},
				form: {
					columnGap: "var(--theme--form--column-gap)",
					rowGap: "var(--theme--form--row-gap)",
					label: {
						foreground: "var(--theme--form--field--label--foreground)",
						fontFamily: "var(--theme--form--field--label--font-family)"
					},
					field: { input: {
						background: "var(--theme--form--field--input--background)",
						foreground: "var(--theme--form--field--input--foreground)",
						foregroundSubdued: "var(--theme--form--field--input--foreground-subdued)",
						borderColor: "var(--theme--form--field--input--border-color)",
						borderColorHover: "var(--theme--form--field--input--border-color-hover)",
						focusRingColor: "var(--theme--form--field--input--focus-ring-color)",
						boxShadow: "var(--theme--form--field--input--box-shadow)",
						height: "2.9375rem",
						padding: "0.6875rem"
					} }
				}
			}
		},
		public: {
			background: "var(--theme--background)",
			foreground: "var(--theme--foreground)",
			foregroundAccent: "var(--theme--foreground-accent)",
			art: {
				background: "#0e1c2f",
				primary: "var(--theme--primary)",
				secondary: "var(--theme--secondary)",
				speed: "1"
			},
			form: {
				columnGap: "var(--theme--form--column-gap)",
				rowGap: "var(--theme--form--row-gap)",
				label: {
					foreground: "var(--theme--form--field--label--foreground)",
					fontFamily: "var(--theme--form--field--label--font-family)"
				},
				field: { input: {
					background: "var(--theme--form--field--input--background)",
					foreground: "var(--theme--form--field--input--foreground)",
					foregroundSubdued: "var(--theme--form--field--input--foreground-subdued)",
					borderColor: "var(--theme--form--field--input--border-color)",
					borderColorHover: "var(--theme--form--field--input--border-color-hover)",
					focusRingColor: "var(--theme--form--field--input--focus-ring-color)",
					boxShadow: "var(--theme--form--field--input--box-shadow)",
					height: "var(--theme--form--field--input--height)",
					padding: "var(--theme--form--field--input--padding)"
				} }
			}
		},
		popover: { menu: {
			background: "#fafcfd",
			borderRadius: "var(--theme--border-radius)",
			boxShadow: "0px 0px 6px 0px rgb(23, 41, 64, 0.2), 0px 0px 12px 2px rgb(23, 41, 64, 0.05)"
		} },
		banner: {
			background: "#0e1c2f",
			padding: "2.25rem",
			borderRadius: "var(--theme--border-radius)",
			avatar: {
				borderRadius: "50%",
				foreground: "var(--theme--primary)",
				background: "#ffffff"
			},
			headline: {
				foreground: "#ffffff",
				fontFamily: "var(--theme--fonts--sans--font-family)",
				fontWeight: "var(--theme--fonts--sans--font-weight)"
			},
			title: {
				foreground: "#ffffff",
				fontFamily: "var(--theme--fonts--display--font-family)",
				fontWeight: "var(--theme--fonts--display--font-weight)"
			},
			subtitle: {
				foreground: "#a2b5cd",
				fontFamily: "var(--theme--fonts--monospace--font-family)",
				fontWeight: "var(--theme--fonts--monospace--font-weight)"
			},
			art: { foreground: "#2e3a4d" }
		}
	}
});

//#endregion
//#region src/themes/light/minimal.ts
var minimal_default = defineTheme({
	id: "Directus Minimal",
	name: "$t:theme_directus_minimal",
	appearance: "light",
	rules: {
		borderWidth: "1px",
		backgroundPage: "color-mix(in srgb, #FFFFFF, var(--theme--primary) 7%)",
		shell: { background: "#FFFFFF" },
		navigation: {
			modules: {
				background: "#FFFFFF",
				button: {
					backgroundActive: "#F1F5F9",
					foreground: "var(--theme--foreground)",
					foregroundHover: "var(--theme--primary)",
					foregroundActive: "var(--theme--primary)",
					backgroundHover: "#F1F5F9",
					background: "#FFFFFF"
				},
				borderWidth: "1px",
				borderColor: "var(--theme--border-color)"
			},
			project: {},
			list: {
				icon: { foreground: "#0F172A" },
				divider: { borderColor: "var(--theme--border-color)" }
			},
			borderWidth: "1px",
			backgroundAccent: "#F1F5F9",
			borderColor: "var(--theme--border-color)"
		},
		backgroundAccent: "#E2E8F0",
		backgroundSubdued: "#F8FAFC",
		background: "#FFFFFF",
		foreground: "#1E293B",
		foregroundAccent: "#0F172A",
		foregroundSubdued: "#94A3B8",
		borderRadius: "0.25rem",
		borderColor: "#E2E8F0",
		borderColorAccent: "#CBD5E1",
		borderColorSubdued: "#F1F5F9",
		form: {
			rowGap: "1.8125rem",
			field: { input: {
				background: "#FFFFFF",
				backgroundSubdued: "#F8FAFC",
				height: "2.9375rem"
			} }
		},
		sidebar: { section: {
			toggle: {
				foreground: "var(--theme--foreground-subdued)",
				foregroundHover: "var(--theme--foreground-accent)",
				foregroundActive: "var(--theme--foreground)"
			},
			form: { field: { input: { height: "2.375rem" } } }
		} },
		public: {
			art: {
				background: "color-mix(in srgb, #FFFFFF, var(--project-color) 10%)",
				primary: "color-mix(in srgb, #FFFFFF, var(--project-color) 70%)",
				secondary: "color-mix(in srgb, #FFFFFF, var(--project-color) 40%)"
			},
			background: "#FFFFFF"
		},
		backgroundNormal: "#F1F5F9",
		secondary: "#64748B",
		primary: "#0F172A",
		primaryBackground: "#F1F5F9",
		primarySubdued: "#F8FAFC",
		primaryAccent: "#E2E8F0",
		secondaryAccent: "#E2E8F0",
		secondaryBackground: "#F1F5F9",
		secondarySubdued: "#F8FAFC",
		fonts: { display: { fontFamily: "system-ui" } }
	}
});

//#endregion
//#region src/themes/index.ts
const dark = [default_default];
const light = [
	default_default$1,
	minimal_default,
	color_match_default
];

//#endregion
//#region src/stores/theme.ts
const useThemeStore = defineStore("🎨 Themes", () => {
	const themes = reactive({
		light,
		dark
	});
	const registerTheme = (theme) => {
		if (theme.appearance === "light") themes.light.push(theme);
		else themes.dark.push(theme);
	};
	return {
		themes,
		registerTheme
	};
});

//#endregion
//#region src/composables/use-theme.ts
const useTheme = (darkMode, themeLight, themeDark, themeLightOverrides, themeDarkOverrides) => {
	const { themes } = storeToRefs(useThemeStore());
	return { theme: computed(() => {
		const themeId = unref(darkMode) ? unref(themeDark) : unref(themeLight);
		const defaultTheme = unref(darkMode) ? default_default : default_default$1;
		const overrides = unref(darkMode) ? unref(themeDarkOverrides) : unref(themeLightOverrides);
		const theme = unref(themes)[unref(darkMode) ? "dark" : "light"].find((theme$1) => theme$1.id === themeId);
		if (!theme) {
			if (themeId && themeId !== defaultTheme.id) console.warn(`Theme "${themeId}" doesn't exist.`);
			return overrides ? merge({}, defaultTheme, { rules: overrides }) : defaultTheme;
		}
		return overrides ? merge({}, defaultTheme, theme, { rules: overrides }) : merge(defaultTheme, theme);
	}) };
};

//#endregion
//#region src/utils/rules-to-css-vars.ts
const rulesToCssVars = (rules) => {
	const flattened = flatten(rules, { delimiter: "--" });
	const getRuleName = (name) => `--theme--${decamelize(name, { separator: "-" })}`;
	return mapKeys(flattened, (_value, key) => getRuleName(key));
};

//#endregion
//#region src/components/theme-provider.vue
const _sfc_main = /* @__PURE__ */ defineComponent({
	__name: "theme-provider",
	props: {
		darkMode: { type: Boolean },
		themeLight: { default: default_default$1.name },
		themeLightOverrides: { default: () => ({}) },
		themeDark: { default: default_default.name },
		themeDarkOverrides: { default: () => ({}) }
	},
	setup(__props) {
		const { darkMode, themeLight, themeDark, themeLightOverrides, themeDarkOverrides } = toRefs(__props);
		const { theme } = useTheme(darkMode, themeLight, themeDark, themeLightOverrides, themeDarkOverrides);
		const cssVariables = computed(() => {
			return rulesToCssVars(unref(theme).rules);
		});
		const { googleFonts } = useFonts(theme);
		useHead({ link: computed(() => {
			let fontsImport = "";
			if (googleFonts.value.length > 0) {
				const fontsString = googleFonts.value.join("&family=");
				fontsImport += `https://fonts.googleapis.com/css2?family=${fontsString}`;
				fontsImport += "\n";
			}
			return fontsImport ? [{
				rel: "stylesheet",
				href: fontsImport
			}] : [];
		}) });
		const cssString = computed(() => {
			return `:root {${Object.entries(unref(cssVariables)).map(([key, value]) => `${key}: ${value};`).join(" ")}}`;
		});
		return (_ctx, _cache) => {
			return openBlock(), createBlock(Teleport, { to: "#theme" }, [createTextVNode(toDisplayString(cssString.value), 1)]);
		};
	}
});
var theme_provider_default = _sfc_main;

//#endregion
export { theme_provider_default as ThemeProvider, defineTheme, rulesToCssVars, useFonts, useTheme, useThemeStore };