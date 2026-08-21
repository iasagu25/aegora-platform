import checkBuiltCode from './check-built-code.js';
import checkDirectusConfig from './check-directus-config.js';
import checkLicense from './check-license.js';
import checkReadme from './check-readme.js';
const validators = [checkReadme, checkLicense, checkDirectusConfig, checkBuiltCode];
export default validators;
