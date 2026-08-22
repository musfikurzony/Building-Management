/* Salary — the staff module's payroll screen, reachable on its own so it
   can carry its own permission. */
import { render as staffRender } from './staff.js';
export const render = (ctx) => staffRender({ ...ctx, params: ['salary'] });
