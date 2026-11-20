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
w.open = () => { throw Error('Native play should open the game process'); };
w.fetch = async (url, options) => {
  calls.push({ url, body: options?.body ? JSON.parse(options.body) : null });
  const demoInfo = {running: false, folder: 'demos', counts: {sherman75: 2, t34_76: 0, tiger1: 0},
    stages: [{id: 'v6_1v2', label: 'V6-2'}], maps: [{id: 'village', label: '마을'}], v6_runs: ['sample']};
  return { ok: true, json: async () => url === '/api/arcade_play' ? {running: true, pid: 123}
    : url === '/api/combat_demo_info' ? demoInfo : { run: 'sample' } };
};
for (const d of w.document.querySelectorAll('dialog')) {
  d.showModal = function () { this.open = true; };
  d.close = function (v) { this.open = false; if (v !== undefined) this.returnValue = v; this.dispatchEvent(new w.Event('close')); };
}
const form = w.document.getElementById('startForm');
// jsdom does not implement all of HTMLFormElement's browser named-property access.
for (const f of [form, w.document.getElementById('demoForm')]) {
  for (const el of f.elements) {
    if (el.name && !f[el.name]) Object.defineProperty(f, el.name, { value: el });
  }
}
form.tank.innerHTML = '<option value="tiger1">Tiger</option>';
form.start_stage.innerHTML = '<option value="">Default</option>';
form.terrain_course.innerHTML = '<option value="">Auto</option><option value="gates">Gates</option>';
w.fixture = {
  settings: { device: 'hybrid', godot: 'TankGame.exe', project: '', python: '' },
  cpu_count: 12,
  tanks: ['tiger1', 'sherman75', 't34_76'],
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
  'await $("arcadePlay").onclick();',
  'if (!$("demoDlg").open || $("demoForm").run.value !== "sample" || !$("demoCounts").textContent.includes("셔먼 2판")) throw Error("Combat demo dialog");',
  '$("demoDlg").close("go"); await new Promise(r => setTimeout(r, 0));',
  'await $("demoV7").onclick();',
  'const f = $("startForm");',
  'if (f.device.value !== "hybrid") throw Error("Hybrid preference lost");',
  'f.run.value = "sample"; f.n_envs.value = 8; f.n_steps.value = 1024;',
  'f.batch_size.value = 2048; f.n_epochs.value = 8;',
  'f.terrain_course.value = "gates";',
  'await $("btnGo").onclick({ preventDefault() {} });',
  '$("trainDevice").value = "hybrid"; await $("btnDevice").onclick();',
  '$("evalEpisodes").value = 2; await $("btnEvaluate").onclick();',
  '$("independentSteps").value = 64; await $("btnIndependent").onclick();',
  'f.mode.value = "v7"; f.mode.onchange();',
  'if (f.run.value !== "V7-Godot-1" || !f.godot.closest(".ctl").hidden) throw Error("Godot defaults");',
  'await $("btnGo").onclick({preventDefault() {}});',
  'S = {alive: false, v7: {}, run_json: {sessions: 0, preparation: "ready", args: {}}, status: {}}; RUN = "V7-1";',
  'openStart(); if (!f.resume.checked || !f.behavior_clone.checked) throw Error("Prepared resume");',
  'f.arcade_tank.value = "sherman75"; f.arcade_tank.onchange(); f.timesteps.value = 1024;',
  'f.demos_dir.value = "recorded demos"; await $("btnGo").onclick({preventDefault() {}});',
  'S.status.tank = "sherman75"; S.v7 = {stages: [{id: "v7_target", label: "링 태그"}], tanks: ["sherman75"],',
  'models: {sherman75: {stage: "v7_target", stage_stats: {v7_target: {recent: [false, true]}}}},',
  'reward_means: {side_seen: 0.25}, reward_episodes: 2}; renderArcadeMap();',
  'if (!$("v7Stages").textContent.includes("50% (2판)") || !$("v7Reward").textContent.includes("0.25")) throw Error("Arcade map");',
  '\n    EPCOL = {objective: 0, success: 1, global_step: 2};\n    EPS = [["a", 1, 10], ["b", 0, 20], ["a", 1, 30]];\n    S.objectives = {a: {stage: "drive_terrain", label: "Approach", color: "#2563eb"},\n                    b: {stage: "drive_terrain", label: "Slope", color: "#9333ea"}};\n    $("xSel").value = "step";\n    window.goalCurves = objectiveSeries(EPS.map((e,i) => [e,i]), "success", 100);\n  ',
  '})();'
].join('\n');
w.eval(script + '\n' + harness);
(async () => {
  await w.checkFinished;
  assert.equal(calls.filter(c => c.url === '/api/arcade_play').length, 1);
  const demo = calls.find(c => c.url === '/api/combat_demo');
  assert.equal(demo.body.tank, 'sherman75');
  assert.equal(demo.body.stage, 'v6_1v2');
  assert.equal(demo.body.run, 'sample');
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
  const [fresh, prepared] = calls.filter(c => c.url === '/api/start' && c.body.curriculum === 'v7').map(c => c.body);
  assert.equal(fresh.rotate, 'tiger1,sherman75,t34_76');
  assert.equal(fresh.rotate_steps, 65536);
  assert.equal(fresh.behavior_clone, true);
  assert.equal(fresh.resume, false);
  assert.equal(prepared.tank, 'sherman75');
  assert.equal(prepared.resume, true);
  assert.equal(prepared.demos_dir, 'recorded demos');
  assert.ok(!('godot' in fresh || 'branch_from' in fresh || 'init_model' in fresh));
  assert.equal(restart.body.device, 'hybrid');
  assert.match(w.document.getElementById('hardwareInfo').textContent, /CPU|cpu/);
  assert.match(w.document.getElementById('hardwareInfo').textContent, /cuda:0/);
  assert.match(w.document.getElementById('hardwareInfo').textContent, /CUDA 준비 완료/);
  console.log('PASS: device selection, PPO settings, restart, GPU status, arcade fresh/prepared launch and stage map');
})().catch(e => { console.error(e); process.exitCode = 1; }).finally(() => w.close());
