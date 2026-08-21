import BaseJoi, { AnySchema, StringSchema as StringSchema$1 } from "joi";
import { Accountability, ClientFilterOperator, Collection, CollectionOverview, CollectionType, FieldFilter, FieldFunction, FieldOverview, Filter, Plural, Policy, RawField, Relation, Role, SchemaOverview, Type, UnknownObject, User } from "@directus/types";
import { Component } from "vue";

//#region shared/abbreviate-number.d.ts
declare function abbreviateNumber(number: number, decimalPlaces?: number, units?: string[]): string;
//#endregion
//#region shared/add-field-flag.d.ts
/**
* Add a flag to a field.
*/
declare function addFieldFlag(field: RawField, flag: string): void;
//#endregion
//#region shared/adjust-date.d.ts
/**
* Adjust a given date by a given change in duration. The adjustment value uses the exact same syntax
* and logic as Vercel's `ms`.
*
* The conversion is lifted straight from `ms`.
*/
declare function adjustDate(date: Date, adjustment: string): Date | undefined;
//#endregion
//#region shared/apply-options-data.d.ts
declare function applyOptionsData(options: Record<string, any>, data: Record<string, any>, skipUndefinedKeys?: string[]): Record<string, any>;
declare function optionToObject<T>(option: T): Exclude<T, string>;
declare function optionToString(option: unknown): string;
//#endregion
//#region shared/array-helpers.d.ts
declare function isIn<T extends readonly string[]>(value: string, array: T): value is T[number];
declare function isTypeIn<T extends {
  type?: string;
}, E extends string>(object: T, array: readonly E[]): object is Extract<T, {
  type?: E;
}>;
//#endregion
//#region shared/compress.d.ts
/**
* Compress any input object or array down to a minimal size reproduction in a string
* Inspired by `jsonpack`
*/
declare function compress(obj: Record<string, any> | Record<string, any>[]): string;
declare function decompress(input: string): unknown;
//#endregion
//#region shared/deep-map.d.ts
/**
* Maps over all values in an array or object recursively and calls the callback on primitive values.
* The called object will not be mutated. The callback will not be called for primitive values.
*
* @example
* deepMap({a: 1, b: [2]}, (value) => String(value)) // {a: "1", b: ["2"]}
*/
declare function deepMap(object: any, callback: (value: any, key: string | number) => any, context?: any): any;
//#endregion
//#region shared/defaults.d.ts
/**
* Returns the input source object with the defaults applied
*
* @example
* ```js
* type Example = {
* 	optional?: boolean;
* 	required: boolean;
* }
* const input: Example = { required: true };
* const output = defaults(input, { optional: false });
* // => { required: true, optional: false }
* ```
*/
declare const defaults: <T extends object>(obj: T, def: Required<Pick<T, Exclude<keyof T, Exclude<{ [K in keyof T]: T[K] extends Exclude<T[keyof T], undefined> ? K : never }[keyof T], undefined>>>>) => Required<T>;
//#endregion
//#region shared/functions.d.ts
declare const functions: Record<FieldFunction, (val: any) => any>;
//#endregion
//#region shared/generate-joi.d.ts
interface StringSchema extends StringSchema$1 {
  contains(substring: string): this;
  icontains(substring: string): this;
  ncontains(substring: string): this;
}
declare const Joi: typeof BaseJoi;
type JoiOptions = {
  requireAll?: boolean;
};
/**
* Generate a Joi schema from a field filter object. This does not support relations or logical operators (_and/_or).
*
* @param filter - Field filter object. Note: does not support _and/_or filters.
* @param [options] - Options for the schema generation.
* @returns Joi schema.
*/
declare function generateJoi(filter: FieldFilter | null, options?: JoiOptions): AnySchema;
//#endregion
//#region shared/get-collection-type.d.ts
/**
* Get the type of collection. One of alias | table. (And later: view)
*
* @param collection Collection object to get the type of
* @returns collection type
*/
declare function getCollectionType(collection: Collection): CollectionType;
//#endregion
//#region shared/get-date-time-formatted.d.ts
declare function getDateTimeFormatted(): string;
//#endregion
//#region shared/get-endpoint.d.ts
declare function getEndpoint(collection: string): string;
//#endregion
//#region shared/get-fields-from-template.d.ts
declare function getFieldsFromTemplate(template?: string | null): string[];
//#endregion
//#region shared/get-filter-operators-for-type.d.ts
type GetFilterOperationsForTypeOptions = {
  includeValidation?: boolean;
};
declare function getFilterOperatorsForType(type: Type, opts?: GetFilterOperationsForTypeOptions): ClientFilterOperator[];
//#endregion
//#region shared/get-functions-for-type.d.ts
declare function getFunctionsForType(type: Type): FieldFunction[];
//#endregion
//#region shared/get-output-type-for-function.d.ts
declare function getOutputTypeForFunction(fn: FieldFunction): Type;
//#endregion
//#region shared/get-redacted-string.d.ts
declare const getRedactedString: (key?: string) => string;
declare const REDACTED_TEXT: string;
//#endregion
//#region shared/get-relation-type.d.ts
type GetRelationOptions = {
  relation: Relation;
  collection: string | null;
  field: string;
};
declare function getRelationType(options: GetRelationOptions & {
  useA2O: true;
}): "m2o" | "o2m" | "a2o" | null;
declare function getRelationType(options: GetRelationOptions & {
  useA2O?: false;
}): "m2o" | "o2m" | "m2a" | null;
//#endregion
//#region shared/get-relation.d.ts
declare function getRelations(relations: Relation[], collection: string, field: string): Relation[];
declare function getRelation(relations: Relation[], collection: string, field: string): Relation | undefined;
declare function getRelationsForCollection(schema: SchemaOverview, collection: string): string[];
//#endregion
//#region shared/get-simple-hash.d.ts
/**
* Generate a simple short hash for a given string
* This is not cryptographically secure in any way, and has a high chance of collision
*/
declare function getSimpleHash(str: string): string;
//#endregion
//#region shared/get-with-arrays.d.ts
/**
* Basically the same as `get` from `lodash`, but will convert nested array values to arrays, so for example:
*
* @example
* ```js
* const obj = { value: [{ example: 1 }, { example: 2 }]}
* get(obj, 'value.example');
* // => [1, 2]
* ```
*/
declare function get(object: Record<string, any> | any[], path: string, defaultValue?: unknown): any;
//#endregion
//#region shared/inject-function-results.d.ts
/**
* Inject function output fields into a given payload for accurate validation
*
* @param payload Any data payload
* @param filter A single level filter rule to verify against
*
* @example
* ```js
* const input = { date: '2022-03-29T11:37:56Z' };
* const filter = { 'year(date)': { _eq: 2022 }}
* const output = applyFunctions(input, filter);
* // { date: '2022-03-29T11:37:56Z', 'year(date)': 2022 }
* ```
*/
declare function injectFunctionResults(payload: Record<string, any>, filter: Filter): Record<string, any>;
//#endregion
//#region shared/is-detailed-update-syntax.d.ts
/**
* Checks if a value is using the detailed update syntax for relational fields
*/
declare function isDetailedUpdateSyntax(value: unknown): value is {
  create: unknown[];
  update: unknown[];
  delete: unknown[];
};
//#endregion
//#region shared/is-dynamic-variable.d.ts
declare function isDynamicVariable(value: any): boolean;
//#endregion
//#region shared/is-object.d.ts
declare function isObject(input: unknown): input is UnknownObject;
//#endregion
//#region shared/is-valid-json.d.ts
declare function isValidJSON(input: string): boolean;
//#endregion
//#region shared/is-vue-component.d.ts
declare function isVueComponent(input: unknown): input is Component;
//#endregion
//#region shared/merge-filters.d.ts
declare function mergeFilters(filterA: Filter | null, filterB: Filter | null, strategy?: "and" | "or"): Filter | null;
//#endregion
//#region shared/move-in-array.d.ts
declare function moveInArray<T = any>(array: T[], fromIndex: number, toIndex: number): T[];
//#endregion
//#region shared/normalize-path.d.ts
/**
* Replace windows style backslashes with unix forwards slashes
*/
declare const normalizePath: (path: string, {
  removeLeading
}?: {
  removeLeading: boolean;
}) => string;
//#endregion
//#region shared/number-generator.d.ts
/**
* Generator function to generate parameter indices.
*/
declare function numberGenerator(): Generator<number, number, number>;
//#endregion
//#region shared/parse-filter-function-path.d.ts
/**
* Parse count(a.b.c) as a.b.count(c) and a.b.count(c.d) as a.b.c.count(d)
*/
declare function parseFilterFunctionPath(path: string): string;
//#endregion
//#region shared/parse-filter.d.ts
type ParseFilterContext = {
  $CURRENT_USER?: User & Record<string, any>;
  $CURRENT_ROLE?: Role & Record<string, any>;
  $CURRENT_ROLES?: (Role & Record<string, any>)[];
  $CURRENT_POLICIES?: (Policy & Record<string, any>)[];
};
type BasicAccountability = Pick<Accountability, "user" | "role" | "roles">;
declare function parseFilter(filter: Filter | null, accountability: BasicAccountability | null, context?: ParseFilterContext, skipCoercion?: boolean): Filter | null;
declare function parsePreset(preset: Record<string, any> | null, accountability: BasicAccountability | null, context: ParseFilterContext): any;
//#endregion
//#region shared/parse-json.d.ts
/**
* Run JSON.parse, but ignore `__proto__` properties. This prevents prototype pollution attacks
*/
declare function parseJSON(input: string): any;
declare function noproto<T>(key: string, value: T): T | void;
//#endregion
//#region shared/parse-now.d.ts
/**
* Resolve a `$NOW` dynamic variable (with optional adjustment) to a `Date`.
*
* Examples:
* - `"$NOW"` → current date/time
* - `"$NOW(-7 days)"` → 7 days ago
* - `"$NOW(+1 month)"` → 1 month from now
*
* Throws if the value is not a valid `$NOW` variable.
*/
declare function parseNow(value: string): Date;
//#endregion
//#region shared/pluralize.d.ts
declare function pluralize<T extends string>(str: T): Plural<T>;
declare function depluralize<T extends string>(str: Plural<T>): T;
//#endregion
//#region shared/process-chunk.d.ts
declare function processChunk<T = unknown>(arr: T[], size: number, callback: (chunk: T[]) => Promise<void>): Promise<void>;
//#endregion
//#region shared/sieve-functions.d.ts
declare function sieveFunctions(data: unknown): unknown;
//#endregion
//#region shared/to-array.d.ts
declare function toArray<T = any>(val: T | T[]): T[];
//#endregion
//#region shared/to-boolean.d.ts
/**
* Convert environment variable to Boolean
*/
declare function toBoolean(value: any): boolean;
//#endregion
//#region shared/validate-payload.d.ts
/**
* Validate the payload against the given filter rules
*
* @param {Filter} filter - The filter rules to check against
* @param {Record<string, any>} payload - The payload to validate
* @param {JoiOptions} [options] - Optional options to pass to Joi
* @returns Array of errors
*/
declare function validatePayload(filter: Filter, payload: Record<string, any>, options?: JoiOptions): BaseJoi.ValidationError[];
//#endregion
//#region shared/get-relation-info.d.ts
type RelationInfo = {
  relation: Relation | null;
  relationType: "o2m" | "m2o" | "a2o" | "o2a" | null;
};
declare function getRelationInfo(relations: Relation[], collection: string | undefined, field: string | undefined): RelationInfo;
//#endregion
//#region shared/deep-map-filter.d.ts
type Quantity = "some" | "none" | null;
declare function deepMapFilter(filter: Filter, callback: (entry: [key: string | number, value: unknown], context: {
  collection: CollectionOverview;
  field: FieldOverview | null;
  relation: Relation | null;
  leaf: boolean;
  function: string | undefined;
  relationType: RelationInfo["relationType"] | null;
  quantity: Quantity;
  targetCollection?: string | undefined;
  object: Record<string, unknown>;
  path: string[];
}) => [key: string | number, value: unknown] | undefined, context: {
  schema: SchemaOverview;
  collection: string;
  relationInfo?: RelationInfo | undefined;
  path?: string[];
}): any;
//#endregion
//#region shared/deep-map-with-schema.d.ts
type DeepMapCallbackContext = {
  collection: CollectionOverview;
  field: FieldOverview;
  relation: Relation | null;
  leaf: boolean;
  relationType: RelationInfo["relationType"] | null;
  object: Record<string, unknown>;
  action?: "create" | "update" | "delete" | undefined;
};
type DeepMapContext = {
  schema: SchemaOverview;
  collection: string;
  relationInfo?: RelationInfo & {
    action?: "create" | "update" | "delete" | undefined;
  };
};
type DeepMapOptions = {
  /** If set to true, fields that exist in the schema but not in the mapped data will be included and with a value of undefined */
  mapNonExistentFields?: boolean;
  /** If set to true, it will map primitive values to objects with primary key on o2m relations */
  mapPrimaryKeys?: boolean;
  /** If set to true, it will map the "create", "update" and "delete" syntax for o2m relations found in deltas */
  detailedUpdateSyntax?: boolean;
  /** If set to true, fields that are in the data but not in the schema will be removed */
  omitUnknownFields?: boolean;
  /** If set to true, a Promise will be returned instead of the value */
  processAsync?: boolean;
  /** If set to true, object reconstruction is skipped. Callback can return void. */
  iterateOnly?: boolean;
  /** Called when a field is not found in the schema. Return a new entry or undefined to omit. */
  onUnknownField?: (entry: DeepMapEntry, context: Pick<DeepMapCallbackContext, "collection" | "object" | "action">) => DeepMapEntry | undefined | void | Promise<DeepMapEntry | undefined | void>;
};
type DeepMapEntry = [key: string | number, value: unknown];
type DeepMapCallback<T> = (entry: DeepMapEntry, context: DeepMapCallbackContext) => T;
/**
* Allows to deep map the data like a response or delta changes with collection, field and relation context for each entry.
* Traversal order of the provided object: [4, 5, 2, 6, 3, 1]
*        [1]
*       /   \
*     [2]   [3]
*    /   \    \
*  [4]   [5]  [6]
*/
declare function deepMapWithSchema(object: unknown, callback: DeepMapCallback<DeepMapEntry | undefined | void>, context: DeepMapContext, options?: DeepMapOptions & {
  processAsync?: false;
}): any;
declare function deepMapWithSchema(object: unknown, callback: DeepMapCallback<Promise<DeepMapEntry | undefined | void>>, context: DeepMapContext, options: DeepMapOptions & {
  processAsync: true;
}): Promise<any>;
//#endregion
export { Joi, JoiOptions, Quantity, REDACTED_TEXT, RelationInfo, StringSchema, abbreviateNumber, addFieldFlag, adjustDate, applyOptionsData, compress, decompress, deepMap, deepMapFilter, deepMapWithSchema, defaults, depluralize, functions, generateJoi, get, getCollectionType, getDateTimeFormatted, getEndpoint, getFieldsFromTemplate, getFilterOperatorsForType, getFunctionsForType, getOutputTypeForFunction, getRedactedString, getRelation, getRelationInfo, getRelationType, getRelations, getRelationsForCollection, getSimpleHash, injectFunctionResults, isDetailedUpdateSyntax, isDynamicVariable, isIn, isObject, isTypeIn, isValidJSON, isVueComponent, mergeFilters, moveInArray, noproto, normalizePath, numberGenerator, optionToObject, optionToString, parseFilter, parseFilterFunctionPath, parseJSON, parseNow, parsePreset, pluralize, processChunk, sieveFunctions, toArray, toBoolean, validatePayload };