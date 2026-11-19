const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync(require('node:path').join(__dirname, '../tankrl/dashboard.html'), 'utf8');
const funcs = ['thin', 'rolling', 'objectiveSeries'].map(name => {
  const start = html.indexOf(`function ${name}(`);
  const end = html.indexOf('\nfunction ', start + 1);
  return html.slice(start, end);
}).join('\n');
const fields = ['global_step', 'success', 'current_stage', 'tank', 'model'];
const context = vm.createContext({
  col: key => fields.indexOf(key), xOf: e => e[0],
  groupOf: () => ({key: 'battle', name: 'Battle', color: '#fff'}),
  $: () => ({value: 'objective'}), TANK_LABEL: {tiger1: 'Tiger', sherman75: 'Sherman'},
});
vm.runInContext(funcs, context);
const row = (x, success, tank=0, model='shared') => [x, success, 20, tank, model];
const series = rows => context.objectiveSeries(rows.map((e,i) => [e,i]), 'success', 100);
const reset = series([row(100, 1), row(200, 1), row(150, 0), row(250, 0)]);
assert.equal(reset.length, 2);
assert.deepEqual(Array.from(reset[0].pts, p=>p[1]), [1, 1]);
assert.deepEqual(Array.from(reset[1].pts, p=>p[1]), [0, 0]);
assert.match(reset[1].name, /재개 2/);
for (const s of reset) assert.ok(s.pts.every((p,i,a) => !i || p[0]>=a[i-1][0]));
assert.equal(series([row(100,1),row(100,0),row(200,1)]).length, 1);
assert.equal(series([row(100,1,0),row(200,0,1),row(300,1,2)]).length, 1);
const tanks = series([row(200,1,0,'tiger1'),row(100,0,1,'sherman75')]);
assert.equal(tanks.length, 2);
assert.match(tanks[0].name, /Tiger/);
assert.match(tanks[1].name, /Sherman/);
console.log('PASS: rollback boundaries, independent moving averages, shared and per-tank model curves');

const filterFuncs = ['objParts', 'filterPred'].map(name => {
  const start = html.indexOf(`function ${name}(`);
  const end = html.indexOf('\nfunction ', start + 1);
  return html.slice(start, end).replace(/let FILTER_SIG[\s\S]*$/, '');
}).join('\n');
const filterContext = vm.createContext({
  S: {objectives: {'final/objective:v1/battle': {stage:'final'}}},
  col: key => ['objective', 'variant'].indexOf(key),
  $: id => ({value:id === 'stgFilter' ? 'final' : 'urban'}),
});
vm.runInContext(filterFuncs, filterContext);
assert.equal(filterContext.filterPred()(['final/objective:v1/battle', 'urban']), true);
assert.equal(filterContext.filterPred()(['final/objective:v1/battle', 'open']), false);
console.log('PASS: final curriculum map variant filtering');
