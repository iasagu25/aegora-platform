import z$1, { z } from "zod";
import { PERMISSION_ACTIONS } from "@directus/constants";

//#region src/assets.ts
const TransformationMethods = [
	"toFormat",
	"jpeg",
	"png",
	"tiff",
	"webp",
	"avif",
	"resize",
	"extend",
	"extract",
	"trim",
	"rotate",
	"flip",
	"flop",
	"sharpen",
	"median",
	"blur",
	"flatten",
	"gamma",
	"negate",
	"normalise",
	"normalize",
	"clahe",
	"convolve",
	"threshold",
	"linear",
	"recomb",
	"modulate",
	"tint",
	"greyscale",
	"grayscale",
	"toColorspace",
	"toColourspace",
	"removeAlpha",
	"ensureAlpha",
	"extractChannel",
	"bandbool"
];

//#endregion
//#region src/database.ts
const DatabaseClients = [
	"mysql",
	"postgres",
	"cockroachdb",
	"sqlite",
	"oracle",
	"mssql",
	"redshift"
];

//#endregion
//#region src/deployment.ts
/**
* Supported deployment provider types
*/
const DEPLOYMENT_PROVIDER_TYPES = ["vercel", "netlify"];

//#endregion
//#region src/extensions/app-extension-config.ts
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

//#endregion
//#region src/extensions/themes.ts
const Color = z.string();
const FamilyName = z.string().meta({ $ref: "FamilyName" });
const FontWeight = z.string().meta({ $ref: "FontWeight" });
const Length = z.string();
const Percentage = z.string();
const BoxShadow = z.string();
const Number = z.string();
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
			speed: Number.optional()
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

//#endregion
//#region src/snapshot.ts
/**
* Indicates the kind of change based on comparisons by deep-diff package
*/
const DiffKind = {
	NEW: "N",
	DELETE: "D",
	EDIT: "E",
	ARRAY: "A"
};

//#endregion
//#region src/users.ts
let UserIntegrityCheckFlag = /* @__PURE__ */ function(UserIntegrityCheckFlag$1) {
	UserIntegrityCheckFlag$1[UserIntegrityCheckFlag$1["None"] = 0] = "None";
	/** Check if the number of remaining admin users is greater than 0 */
	UserIntegrityCheckFlag$1[UserIntegrityCheckFlag$1["RemainingAdmins"] = 1] = "RemainingAdmins";
	/** Check if the number of users is within the limits */
	UserIntegrityCheckFlag$1[UserIntegrityCheckFlag$1["UserLimits"] = 2] = "UserLimits";
	UserIntegrityCheckFlag$1[UserIntegrityCheckFlag$1["All"] = 3] = "All";
	return UserIntegrityCheckFlag$1;
}({});

//#endregion
//#region src/websockets/base.ts
const zodStringOrNumber = z.union([z.string(), z.number()]);
const WebSocketMessage = z.object({
	type: z.string(),
	uid: zodStringOrNumber.optional()
}).passthrough();

//#endregion
//#region src/websockets/type.ts
const TYPE = { COLLAB: "collab" };

//#endregion
//#region src/websockets/collab.ts
const COLLAB_BUS = "collab";
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
export { ACTION, COLLAB_BUS, COLORS, ClientMessage, DEPLOYMENT_PROVIDER_TYPES, DatabaseClients, DiffKind, ExtensionSandboxOptions, ExtensionSandboxRequestedScopes, SplitEntrypoint, ThemeSchema, TransformationMethods, UserIntegrityCheckFlag, TYPE as WS_TYPE, WebSocketMessage, zodStringOrNumber };