//#region browser/css-var.d.ts
/**
* Get the value of a globally registered CSS variable
*/
declare function cssVar(name: string, element?: Element): string;
//#endregion
//#region browser/same-origin.d.ts
declare function sameOrigin(url1: string, url2: string): boolean;
//#endregion
export { cssVar, sameOrigin };