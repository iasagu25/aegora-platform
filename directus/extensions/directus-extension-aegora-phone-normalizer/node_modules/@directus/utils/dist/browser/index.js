//#region browser/css-var.ts
/**
* Get the value of a globally registered CSS variable
*/
function cssVar(name, element = document.body) {
	return getComputedStyle(element ?? document.body).getPropertyValue(name).trim();
}

//#endregion
//#region browser/same-origin.ts
function sameOrigin(url1, url2) {
	try {
		return new URL(url1).origin === new URL(url2).origin;
	} catch {
		return false;
	}
}

//#endregion
export { cssVar, sameOrigin };