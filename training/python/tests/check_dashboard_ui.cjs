// Optional DOM integration check. Requires jsdom on NODE_PATH; no browser or training starts.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');
const page = fs.readFileSync(path.join(__dirname, '../tankrl/dashboard.html'), 'utf8');
const script = page.match(/<script>([\s\S]*)<\/script>/)[1]
  .replace(/init\(\)\.catch\([\s\S]*$/, '');
const dom = new JSDOM(page, { runScripts: 'outside-only', url: 'http://127.0.0.1/' });
const w = dom.window;
const calls = [];
w.confirm = () => true;
w.fetch = async (url, options) => {
  calls.push({ url, body: options?.body ? JSON.parse(options.body) : null });
  return { ok: true, json: async () => ({ run: 'sample' }) };
};
w.document.querySelector('dialog').showModal = function () { this.open = true; };
w.document.querySelector('dialog').close = function () { this.open = false; };
const form = w.document.getElementById('startForm');
// jsdom does not implement all of HTMLFormElement's browser named-property access.
for (const el of form.elements) {
  if (el.name && !form[el.name]) Object.defineProperty(form, el.name, { value: el });
}
form.tank.innerHTML = '<option value="tiger1">Tiger</option>';
form.start_stage.innerHTML = '<option value="">Default</option>';
form.terrain_course.innerHTML = '<option value="">Auto</option><option value="gates">Gates</option>';
w.fixture = {
  settings: { device: 'hybrid', godot: 'TankGame.exe', project: '', python: '' },
  cpu_count: 12,
  deps: { runtime: { cuda_available: true, torch: '2.15.0+cu132', cuda_version: '13.2',
    gpus: [{ name: 'RTX 4070 SUPER' }] } }
};
const harness = [
  'window.checkFinished = (async () => {',
  'INFO = window.fixture; RUN = "sample";',
  'S = { alive: true, status: { runtime: { device: "cuda:0", requested_device: "hybrid",',
  'inference_device: "cpu", update_device: "cuda:0", gpu_name: "RTX 4070 SUPER",',
  'batch_size: 2048, rollout_size: 8192, torch_threads: 1 } } };',
  'wire(); renderHardware(); openStart();',
  'const f = $("startForm");',
  'if (f.device.value !== "hybrid") throw Error("Hybrid preference lost");',
  'f.run.value = "sample"; f.n_envs.value = 8; f.n_steps.value = 1024;',
  'f.batch_size.value = 2048; f.n_epochs.value = 8;',
  'f.terrain_course.value = "gates";',
  'await $("btnGo").onclick({ preventDefault() {} });',
  '$("trainDevice").value = "hybrid"; await $("btnDevice").onclick();',
  '$("evalEpisodes").value = 2; await $("btnEvaluate").onclick();',
  '$("independentSteps").value = 64; await $("btnIndependent").onclick();',
  '\n    EPCOL = {objective: 0, success: 1, global_step: 2};\n    EPS = [["a", 1, 10], ["b", 0, 20], ["a", 1, 30]];\n    S.objectives = {a: {stage: "drive_terrain", label: "Approach", color: "#2563eb"},\n                    b: {stage: "drive_terrain", label: "Slope", color: "#9333ea"}};\n    $("xSel").value = "step";\n    window.goalCurves = objectiveSeries(EPS.map((e,i) => [e,i]), "success", 100);\n  ',
  '})();'
].join('\n');
w.eval(script + '\n' + harness);
(async () => {
  await w.checkFinished;
  assert.equal(w.goalCurves.length, 2);
  assert.equal(w.goalCurves[0].color, '#2563eb');
  assert.deepEqual(Array.from(w.goalCurves[0].pts, p => p[1]), [1, 1]);
  assert.deepEqual(Array.from(w.goalCurves[1].pts, p => p[1]), [0]);
  const start = calls.find(c => c.url === '/api/start');
  const restart = calls.find(c => c.url === '/api/restart');
  const evaluation = calls.find(c => c.url === '/api/evaluate');
  assert.equal(evaluation.body.run, 'sample');
  assert.equal(evaluation.body.episodes, 2);
  assert.equal(evaluation.body.modes, 'mixed');
  const independent = calls.find(c => c.url === '/api/train_individuals');
  assert.equal(independent.body.run, 'sample');
  assert.equal(independent.body.timesteps, 64);
  assert.equal(start.body.device, 'hybrid');
  assert.equal(start.body.n_steps, 1024);
  assert.equal(start.body.batch_size, 2048);
  assert.equal(start.body.n_epochs, 8);
  assert.equal(start.body.terrain_course, 'gates');
  assert.equal(restart.body.device, 'hybrid');
  assert.match(w.document.getElementById('hardwareInfo').textContent, /CPU|cpu/);
  assert.match(w.document.getElementById('hardwareInfo').textContent, /cuda:0/);
  assert.match(w.document.getElementById('hardwareInfo').textContent, /CUDA 준비 완료/);
  console.log('PASS: device selection, PPO settings, restart payload and GPU status DOM');
})().catch(e => { console.error(e); process.exitCode = 1; }).finally(() => w.close());
