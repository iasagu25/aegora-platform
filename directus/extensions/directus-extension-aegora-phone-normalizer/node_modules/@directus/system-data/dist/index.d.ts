//#region src/types.d.ts
type RelationMeta = {
  id: number;
  many_collection: string;
  many_field: string;
  one_collection: string | null;
  one_field: string | null;
  one_collection_field: string | null;
  one_allowed_collections: string[] | null;
  one_deselect_action: "nullify" | "delete";
  junction_field: string | null;
  sort_field: string | null;
  system?: boolean;
};
type CollectionTranslations = {
  language: string;
  translation: string;
  singular: string;
  plural: string;
};
type CollectionMeta = {
  collection: string;
  note: string | null;
  hidden: boolean;
  singleton: boolean;
  icon: string | null;
  color: string | null;
  translations: CollectionTranslations[] | null;
  display_template: string | null;
  preview_url: string | null;
  versioning: boolean;
  autosave_revision_interval: number | null;
  sort_field: string | null;
  archive_field: string | null;
  archive_value: string | null;
  unarchive_value: string | null;
  archive_app_filter: boolean;
  item_duplication_fields: string[] | null;
  accountability: "all" | "activity" | null;
  system: boolean | null;
  sort: number | null;
  group: string | null;
  collapse: "open" | "closed" | "locked";
  status: "active" | "inactive";
};
type BaseCollectionMeta = Pick<CollectionMeta, "collection" | "note" | "hidden" | "singleton" | "icon" | "translations" | "versioning" | "autosave_revision_interval" | "item_duplication_fields" | "accountability" | "group" | "system" | "status">;
type DataCollectionMeta = Partial<BaseCollectionMeta> & Pick<BaseCollectionMeta, "collection" | "note">;
type FieldMeta = {
  id: number;
  collection: string;
  field: string;
  group: string | null;
  hidden: boolean;
  interface: string | null;
  display: string | null;
  options: Record<string, any> | null;
  display_options: Record<string, any> | null;
  readonly: boolean;
  required: boolean;
  sort: number | null;
  special: string[] | null;
  translations: FieldTranslations[] | null;
  width: Width | null;
  note: string | null;
  clear_hidden_value_on_save?: boolean;
  conditions: Condition[] | null;
  validation: Filter | null;
  validation_message: string | null;
  searchable: boolean;
  system?: true;
};
type FieldTranslations = {
  language: string;
  translation: string;
};
type Width = "half" | "half-left" | "half-right" | "full" | "fill";
type Condition = {
  name: string;
  rule: Record<string, any>;
  readonly?: boolean;
  hidden?: boolean;
  options?: Record<string, any>;
  required?: boolean;
  clear_hidden_value_on_save?: boolean;
};
type Filter = LogicalFilter | FieldFilter;
type LogicalFilterOR = {
  _or: Filter[];
};
type LogicalFilterAND = {
  _and: Filter[];
};
type LogicalFilter = LogicalFilterOR | LogicalFilterAND;
type FieldFilter = {
  [field: string]: FieldFilterOperator | FieldValidationOperator | FieldFilter;
};
type FieldFilterOperator = {
  _eq?: string | number | boolean;
  _neq?: string | number | boolean;
  _lt?: string | number;
  _lte?: string | number;
  _gt?: string | number;
  _gte?: string | number;
  _in?: (string | number)[];
  _nin?: (string | number)[];
  _null?: boolean;
  _nnull?: boolean;
  _contains?: string;
  _ncontains?: string;
  _icontains?: string;
  _starts_with?: string;
  _nstarts_with?: string;
  _istarts_with?: string;
  _nistarts_with?: string;
  _ends_with?: string;
  _nends_with?: string;
  _iends_with?: string;
  _niends_with?: string;
  _between?: (string | number)[];
  _nbetween?: (string | number)[];
  _empty?: boolean;
  _nempty?: boolean;
  _intersects?: string;
  _nintersects?: string;
  _intersects_bbox?: string;
  _nintersects_bbox?: string;
};
type FieldValidationOperator = {
  _submitted?: boolean;
  _regex?: string;
};
type Permission = {
  id?: number;
  policy: string | null;
  collection: string;
  action: PermissionsAction;
  permissions: Filter | null;
  validation: Filter | null;
  presets: Record<string, any> | null;
  fields: string[] | null;
  system?: true;
};
type PermissionsAction = "create" | "read" | "update" | "delete" | "share";
type DataPermission = Partial<Permission> & Pick<Permission, "collection" | "action">;
type FieldIndex = {
  collection: string;
  field: string;
};
//#endregion
//#region src/collections/index.d.ts
declare const systemCollectionRows: BaseCollectionMeta[];
declare const systemCollectionNames: string[];
declare function isSystemCollection(collection: string): boolean;
//#endregion
//#region src/relations/index.d.ts
declare const systemRelationRows: RelationMeta[];
//#endregion
//#region src/fields/index.d.ts
declare const systemFieldRows: FieldMeta[];
declare const systemIndexRows: FieldIndex[];
declare function hasSystemIndex(collection: string, field: string): boolean;
declare function isSystemField(collection: string, field: string): boolean;
//#endregion
//#region src/app-access-permissions/index.d.ts
declare const schemaPermissions: Permission[];
declare const appAccessMinimalPermissions: Permission[];
declare const appRecommendedPermissions: Partial<Permission>[];
//#endregion
export { BaseCollectionMeta, CollectionMeta, CollectionTranslations, Condition, DataCollectionMeta, DataPermission, FieldFilter, FieldFilterOperator, FieldIndex, FieldMeta, FieldTranslations, FieldValidationOperator, Filter, LogicalFilter, LogicalFilterAND, LogicalFilterOR, Permission, PermissionsAction, RelationMeta, Width, appAccessMinimalPermissions, appRecommendedPermissions, hasSystemIndex, isSystemCollection, isSystemField, schemaPermissions, systemCollectionNames, systemCollectionRows, systemFieldRows, systemIndexRows, systemRelationRows };