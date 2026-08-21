import type { Ora } from 'ora';
import type { Report } from '../../types.js';
interface Validator {
    name: string;
    handler: (spinner: Ora, reports: Array<Report>) => Promise<string>;
}
declare const validators: Validator[];
export default validators;
