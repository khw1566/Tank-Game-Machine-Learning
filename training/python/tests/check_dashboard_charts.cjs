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

const rateStart = html.indexOf('function trainingRatePoints(');
const rateEnd = html.indexOf('\nfunction ', rateStart + 1);
const rateColumns = ['wall_time', 'global_step', 'model', 'tank'];
const rateContext = vm.createContext({col: name => rateColumns.indexOf(name)});
vm.runInContext(html.slice(rateStart, rateEnd), rateContext);
const models = ['tiger1', 'sherman75'];
const segment = (time, step, model) => Array.from({length: 11}, (_, i) => [time + i, step + 1000 * i, model, 0]);
const recording = [
  ...segment(0, 2500000, 'tiger1'),
  ...segment(11, 800000, 'sherman75'),
  ...segment(22, 3000000, 'tiger1'),
  ...segment(33, 2500000, 'tiger1'), // restored checkpoint
  ...segment(700, 2510000, 'tiger1'), // resumed after an idle gap
];
const runRates = (rows, selected = '') => rateContext.trainingRatePoints(rows, selected, models, e => e[1]);
const rates = runRates(recording);
const points = rows => Array.from(rows, row => Array.from(row));
assert.deepEqual(points(rates.decisions), [2510000, 810000, 3010000, 2510000, 2520000].map(x => [x, 1000, true]));
assert.deepEqual(Array.from(rates.perMinute, p => p[1]), [60, 60, 60, 60, 60]);
assert.deepEqual(points(runRates(recording, 'sherman75').decisions), [[810000, 1000, true]]);
const shared = segment(0, 1000000, 'shared').map((row, index) => [row[0], row[1], row[2], index % 2]);
assert.deepEqual(points(runRates(shared, 'tiger1').decisions), [[1010000, 1000, true]]);
assert.equal(runRates([[1, 100, 'tiger1', 0], [1, 130, 'tiger1', 0]]).decisions.length, 0);
console.log('PASS: throughput across tank rotations, rollback, idle gaps and shared-policy episodes');
