'use strict';
// Deterministic logic harness for the actual bundled page script. No browser,
// synthetic mouse, phone connection or order is involved.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const html = fs.readFileSync(path.join(__dirname, '../Calibration/index.html'), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1]
  .replace(/syncClock\(\); loadPlan\(\); summary\(\);\s*$/, '');
let passed = 0;

function harness() {
  let now = 100000, visibility = 'visible', visibilityCost = 0;
  const timeOrigin = 1800000000000;
  const elements = new Map(), requests = [], listeners = new Map();
  class Element {
    constructor() { this.textContent = ''; this.disabled = false; this.children = []; this.classes = new Set(); }
    appendChild(child) { this.children.push(child); }
    prepend(child) { this.children.unshift(child); }
    addEventListener(type, callback) { listeners.set(type, callback); }
    get classList() { return {add: value => this.classes.add(value), remove: value => this.classes.delete(value)}; }
  }
  const element = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
  let responder = async (url, body) => ({runId: body?.runId || '', clockId: body?.clockId,
    timeBasis: body?.timeBasis || 'raw-system', sampleCount: body?.samples?.length || 0, matchedSendCount: 0});
  const context = vm.createContext({console, Date, JSON, Number, Math, Map, Set, Promise,
    performance: {timeOrigin, now: () => now},
    window: {PointerEvent: function PointerEvent() {}},
    document: {getElementById: element, createElement: () => new Element(),
      addEventListener(type, callback) { listeners.set('document:' + type, callback); },
      get visibilityState() { now += visibilityCost; return visibility; }},
    fetch: async (url, options) => {
      const body = options.body ? JSON.parse(options.body) : undefined;
      requests.push({url, body});
      const json = await responder(url, body);
      return {ok: !json.error, statusText: json.error || 'OK', json: async () => json};
    },
    setInterval: () => 0,
    setTimeout: (callback, delay) => { if (delay === 30) { now += 30; Promise.resolve().then(callback); } return 0; }
  });
  vm.runInContext(source, context, {filename: 'Calibration/index.html'});
  const evaluate = code => vm.runInContext(code, context);
  const get = code => JSON.parse(JSON.stringify(evaluate(code)));
  const assign = (name, value) => evaluate(name + ' = ' + JSON.stringify(value));
  const baseClock = (id = 'clock-a', basis = 'ntp-utc') => ({clockId: id, timeBasis: basis,
    clockFresh: true, offsetMs: 100, rttMs: 4, uncertaintyEstimateMs: 2,
    ntpEstimatedUncertaintyMs: 8, calibratedAtPhoneMs: timeOrigin + now - 1000,
    calibratedAtMacMs: timeOrigin + now - 900, source: 'test NTP', clockValidUntilMs: timeOrigin + now + 120000});
  const setup = (runId = 'run-a', id = 'clock-a', receivedAfterTarget = 30) => {
    const c = baseClock(id);
    assign('clock', c);
    assign('plan', {runId, clockId: id, timeBasis: 'ntp-utc',
      targetsMs: [timeOrigin + now + 100 - receivedAfterTarget], compensationMs: 0});
    assign('localSamples', []); assign('straySamples', []);
    return c;
  };
  const timeReply = (id = 'clock-a', fresh = true, rtt = 10) => {
    const start = timeOrigin + now;
    now += rtt + 2;
    return {receiveMs: start + 100 + rtt / 2, sendMs: start + 102 + rtt / 2,
      clockId: id, timeBasis: 'ntp-utc', clockFresh: fresh,
      ntpEstimatedUncertaintyMs: 8, source: 'test NTP', clockValidUntilMs: start + 120000};
  };
  return {evaluate, get, assign, setup, baseClock, timeReply, requests, element, listeners,
    setResponder: value => { responder = value; }, setVisibility: value => { visibility = value; },
    setVisibilityCost: value => { visibilityCost = value; }, advance: value => { now += value; },
    get now() { return timeOrigin + now; }};
}
async function settle() { for (let n = 0; n < 16; n++) await Promise.resolve(); }
async function check(name, body) { await body(); passed++; console.log('PASS ' + name); }

(async () => {
  await check('北京时间格式含毫秒并正确跨日，raw 标签不会伪称 NTP', () => {
    const h = harness();
    const epoch = Date.UTC(2026, 9, 29, 16, 0, 0, 40);
    assert.equal(h.evaluate('formatBeijing(' + epoch + ')'), '00:00:00.040');
    assert.equal(h.evaluate('formatBeijing(' + epoch + ', true)'), '2026-10-30 00:00:00.040');
    assert.equal(h.evaluate('formatBeijing(NaN)'), '—');
    h.assign('plan', {runId: 'raw', targetsMs: [epoch], timeBasis: 'raw-system', clockId: 'raw-id'});
    h.evaluate('renderBasis()');
    assert.match(h.element('time-basis').textContent, /不是 NTP/);
  });
  await check('四戳校时计算偏移，非法或倒序时间拒绝', () => {
    const h = harness();
    const value = h.get('estimateClock(1000,1105,1107,1012)');
    assert.equal(value.offsetMs, 100); assert.equal(value.rttMs, 10);
    assert.equal(value.uncertaintyEstimateMs, 5);
    assert.throws(() => h.evaluate('estimateClock(1000,1107,1105,1012)'));
    assert.throws(() => h.evaluate('estimateClock(1000,1100,1200,1010)'));
  });
  await check('NTP 漂移估计随校时年龄增加，未知时间基准不默认为有效', () => {
    const h = harness(); h.setup();
    h.evaluate('clock.ntpEstimateAtPhoneMs = phoneNow(); clock.ntpDriftPPM = 50');
    assert.equal(h.evaluate('absoluteUncertainty(clock)'), 10);
    h.advance(60000); assert.equal(h.evaluate('absoluteUncertainty(clock)'), 13);
    assert.equal(h.evaluate("validPlan({runId:'bad',timeBasis:'unknown-clock',targetsMs:[1000]})"), false);
  });
  await check('回调入口先记时，后续 DOM 工作与上传等待不改变接收时间', async () => {
    const h = harness(); h.setup();
    const captured = h.now;
    h.setVisibilityCost(200);
    let finish;
    h.setResponder(() => new Promise(resolve => { finish = resolve; }));
    h.evaluate("record({type:'pointerup'})");
    const sample = h.get('localSamples[0]');
    assert.equal(sample.receivedMacMs, captured + 100);
    assert.equal(sample.errorMs, 30);
    assert.equal(h.requests[0].body.samples[0].receivedMacMs, captured + 100);
    h.advance(500);
    finish({runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc', sampleCount: 1, matchedSendCount: 0});
    await settle();
    assert.equal(h.get('localSamples[0]').receivedMacMs, captured + 100);
    assert.equal(h.element('received-time').textContent, h.evaluate('formatBeijing(' + (captured + 100) + ')'));
  });
  await check('过期、异基准及 NTP 已过有效截止时间的点击都不计样本', () => {
    for (const kind of ['age', 'identity', 'basis', 'source-expiry']) {
      const h = harness(); h.setup();
      if (kind === 'age') h.advance(60001);
      if (kind === 'identity') h.evaluate("clock.clockId = 'other-clock'");
      if (kind === 'basis') h.evaluate("clock.timeBasis = 'raw-system'");
      if (kind === 'source-expiry') h.evaluate('clock.clockValidUntilMs = phoneNow()+99');
      h.evaluate("record({type:'pointerup'})");
      assert.equal(h.get('localSamples.length'), 0, kind);
      assert.equal(h.requests.length, 0, kind);
    }
  });
  await check('20 轮只采用同一 NTP 基准，最低 RTT 校时后发送空样本就绪回执', async () => {
    const h = harness(); h.setup(); let n = 0;
    h.evaluate('plan.targetsMs = [phoneNow()+15100]');
    h.setResponder((url, body) => {
      if (url === '/time') return h.timeReply('clock-a', true, ++n === 9 ? 2 : 10);
      return {runId: body?.runId || 'run-a', clockId: body?.clockId || 'clock-b', timeBasis: body?.timeBasis || 'ntp-utc', sampleCount: 0, matchedSendCount: 0};
    });
    await h.evaluate('syncClock()'); await settle();
    assert.equal(n, 20);
    assert.equal(h.get('clock.rttMs'), 2); assert.equal(h.get('clock.offsetMs'), 100);
    assert.equal(h.element('uncertainty').textContent, '估计 ±9.000 ms');
    const ready = h.requests.find(value => value.url === '/samples').body;
    assert.equal(ready.runId, 'run-a'); assert.equal(ready.clockId, 'clock-a');
    assert.equal(ready.clock.clockId, 'clock-a'); assert.deepEqual(ready.samples, []);
  });
  await check('NTP 基准中途切换或来源过期时不发送就绪回执', async () => {
    for (const kind of ['change', 'expired']) {
      const h = harness(); h.setup(); let n = 0;
      h.setResponder(url => {
        assert.equal(url, '/time'); n++;
        return h.timeReply(kind === 'change' && n > 8 ? 'clock-b' : 'clock-a', kind !== 'expired');
      });
      await h.evaluate('syncClock()'); await settle();
      assert.equal(h.get('clock'), null);
      assert.equal(h.requests.filter(value => value.url === '/samples').length, 0);
    }
  });
  await check('同一 runId 变更 clockId 也重置样本并重新校时', async () => {
    const h = harness(); h.setup();
    h.assign('localSamples', [{index: 1, receivedMacMs: 1234}]);
    const target = h.now + 100 + 15000;
    h.setResponder((url, body) => {
      if (url === '/plan') return {runId: 'run-a', clockId: 'clock-b', timeBasis: 'ntp-utc', targetsMs: [target]};
      if (url === '/time') return h.timeReply('clock-b');
      return {runId: body.runId, clockId: body.clockId, timeBasis: body.timeBasis, sampleCount: 0, matchedSendCount: 0};
    });
    await h.evaluate('loadPlan()'); await settle();
    assert.equal(h.get('localSamples.length'), 0);
    assert.equal(h.get('clock.clockId'), 'clock-b');
    assert.equal(h.requests.filter(value => value.url === '/time').length, 20);
  });
  await check('复用同基准新鲜校时的新计划也发送空样本就绪回执', async () => {
    const h = harness(); h.setup();
    h.setResponder((url, body) => url === '/plan'
      ? {runId: 'run-b', clockId: 'clock-a', timeBasis: 'ntp-utc', targetsMs: [h.now + 15100]}
      : {runId: body.runId, clockId: body.clockId, timeBasis: body.timeBasis, sampleCount: 0, matchedSendCount: 0});
    await h.evaluate('loadPlan()'); await settle();
    assert.equal(h.requests.filter(value => value.url === '/time').length, 0);
    const ready = h.requests.find(value => value.url === '/samples').body;
    assert.equal(ready.runId, 'run-b'); assert.deepEqual(ready.samples, []);
  });
  await check('等待较长时临近首击刷新，采样开始后不在连点中途校时', async () => {
    const h = harness(); h.setup();
    h.evaluate('clock.calibratedAtPhoneMs -= 44000');
    h.assign('plan', {runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc', targetsMs: [h.now + 30100]});
    assert.equal(h.evaluate('needsNearTargetRefresh(plan,clock)'), false);
    h.advance(11000);
    assert.equal(h.evaluate('needsNearTargetRefresh(plan,clock)'), true);
    h.assign('localSamples', [{index: 1}]);
    assert.equal(h.evaluate('needsNearTargetRefresh(plan,clock)'), false);
  });
  await check('批量采样中途拒绝换校时时钟，完成后校时不会重传旧样本', async () => {
    const h = harness(); h.setup();
    h.evaluate('plan.targetsMs.push(plan.targetsMs[0]+200)');
    h.assign('localSamples', [{index: 1, receivedMacMs: h.now + 100}]);
    const oldCalibrated = h.get('clock.calibratedAtPhoneMs');
    await h.evaluate('syncClock()');
    assert.equal(h.requests.length, 0);
    assert.equal(h.get('clock.calibratedAtPhoneMs'), oldCalibrated);
    h.assign('localSamples', [{index: 1, receivedMacMs: h.now + 100}, {index: 2, receivedMacMs: h.now + 300}]);
    h.setResponder(url => { assert.equal(url, '/time'); return h.timeReply('clock-a'); });
    await h.evaluate('syncClock()'); await settle();
    assert.equal(h.requests.filter(value => value.url === '/samples').length, 0);
    assert.equal(h.get('localSamples.length'), 2);
  });
  await check('打开过去的 NTP 报告只读结果，不提交新校时的空回执', async () => {
    const h = harness(); h.setup();
    const oldTarget = h.now - 5000;
    h.setResponder(url => {
      if (url === '/plan') return {runId: 'past-run', clockId: 'clock-a', timeBasis: 'ntp-utc', targetsMs: [oldTarget]};
      if (url === '/summary') return {runId: 'past-run', clockId: 'clock-a', timeBasis: 'ntp-utc',
        sampleCount: 1, matchedSendCount: 1, latestTargetMs: oldTarget, latestSentUpMs: oldTarget + 3,
        latestReceivedMs: oldTarget + 33, medianLatencyMs: 30, p50ErrorMs: 33, samplesClockValidAtEvent: true};
      if (url === '/time') return h.timeReply('clock-a');
      throw Error('past report must not POST samples');
    });
    await h.evaluate('loadPlan()'); await settle();
    assert.equal(h.requests.filter(value => value.url === '/samples').length, 0);
    assert.equal(h.element('latency').textContent, '30.000 ms');
    assert.equal(h.element('received-time').textContent, h.evaluate('formatBeijing(' + (oldTarget + 33) + ')'));
  });
  await check('Mac 报告计划 NTP 已失效时，立即停止接受新点击且不循环重校时', async () => {
    const h = harness(); h.setup();
    h.setResponder(url => {
      if (url === '/plan') return {runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc',
        targetsMs: [h.now + 15100], clockFresh: false};
      throw Error('expired plan must not sync or upload');
    });
    await h.evaluate('loadPlan()');
    assert.equal(h.get('clock'), null);
    h.evaluate("record({type:'pointerup'})");
    assert.equal(h.get('localSamples.length'), 0);
    assert.equal(h.requests.length, 1);
  });
  await check('重开已完成或部分报告只读，计数和倒计时反映已保存结果且不覆盖旧点击', () => {
    for (const total of [1, 3]) {
      const h = harness(); h.setup();
      if (total === 3) h.evaluate('plan.targetsMs.push(plan.targetsMs[0]+200,plan.targetsMs[0]+400)');
      h.assign('savedResult', {runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc',
        sampleCount: 1, matchedSendCount: 1, latestTargetMs: h.now, latestSentUpMs: h.now + 3,
        latestReceivedMs: h.now + 33, medianLatencyMs: 30, p50ErrorMs: 33, samplesClockValidAtEvent: true});
      assert.equal(h.evaluate('applySummary(savedResult)'), true);
      assert.equal(h.element('counter').textContent, '1 / ' + total + ' 次');
      assert.match(h.element('countdown').textContent, total === 1 ? /本轮接收完成/ : /本页只读/);
      h.evaluate("record({type:'pointerup'})");
      assert.equal(h.get('localSamples.length'), 0);
      assert.equal(h.requests.length, 0);
      assert.match(h.element('notice').textContent, /不会覆盖原来的点击/);
    }
  });
  await check('本页自身开始的部分采样仍能继续收集下一次点击', async () => {
    const h = harness(); h.setup();
    const received = h.now + 100;
    h.assign('plan', {runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc',
      targetsMs: [received - 30, received + 170, received + 370], expectedLatencyMs: 30});
    h.assign('localSamples', [{index: 1, receivedMacMs: received}]);
    h.assign('latestSummary', {runId: 'run-a', sampleCount: 1});
    h.advance(200); h.evaluate("record({type:'pointerup'})"); await settle();
    assert.equal(h.get('localSamples.length'), 2);
    assert.equal(h.get('localSamples[1].index'), 2);
    assert.equal(h.requests[0].body.samples.length, 2);
  });
  await check('在途旧轮上传不会把旧点击改写成新 runId，旧响应不覆盖新轮界面', async () => {
    const h = harness(); h.setup(); let finishA;
    h.setResponder((url, body) => body.runId === 'run-a'
      ? new Promise(resolve => { finishA = resolve; })
      : {runId: body.runId, clockId: body.clockId, timeBasis: body.timeBasis, sampleCount: 1, matchedSendCount: 0});
    h.evaluate("record({type:'pointerup'})");
    const first = h.requests[0].body;
    h.advance(1000); h.setup('run-b', 'clock-b');
    h.element('median').textContent = 'new-run';
    h.evaluate("record({type:'pointerup'})");
    finishA({runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc', sampleCount: 1,
      matchedSendCount: 1, p50ErrorMs: 999, medianLatencyMs: 999});
    await settle();
    assert.equal(first.runId, 'run-a'); assert.equal(first.clockId, 'clock-a');
    assert.equal(h.requests[1].body.runId, 'run-b'); assert.equal(h.requests[1].body.clockId, 'clock-b');
    assert.notEqual(h.requests[0].body.samples[0].receivedMacMs, h.requests[1].body.samples[0].receivedMacMs);
    assert.notEqual(h.element('median').textContent, '999.000 ms');
  });
  await check('异轮与异 clockId 的 summary 都拒绝，正确结果显示三个时刻', () => {
    const h = harness(); h.setup();
    h.element('median').textContent = 'unchanged';
    assert.equal(h.evaluate("applySummary({runId:'old',clockId:'clock-a',p50ErrorMs:999})"), false);
    assert.equal(h.evaluate("applySummary({runId:'run-a',clockId:'clock-b',p50ErrorMs:999})"), false);
    assert.equal(h.element('median').textContent, 'unchanged');
    const t = Date.UTC(2026, 9, 30, 10, 30, 0);
    h.assign('testSummary', {runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc',
      latestTargetMs: t, latestSentUpMs: t + 3, latestReceivedMs: t + 33,
      p50ErrorMs: 33, medianLatencyMs: 30, sampleCount: 1, matchedSendCount: 1});
    assert.equal(h.evaluate('applySummary(testSummary)'), true);
    assert.equal(h.element('target-time').textContent, '18:30:00.000');
    assert.equal(h.element('sent-time').textContent, '18:30:00.003');
    assert.equal(h.element('received-time').textContent, '18:30:00.033');
  });
  await check('晚读报告时当前授时过期，不会把捕获时有效的 NTP 点击作废', () => {
    const h = harness(); h.setup();
    const t = Date.UTC(2026, 9, 30, 10, 30, 0);
    h.assign('pastSummary', {runId: 'run-a', clockId: 'clock-a', timeBasis: 'ntp-utc',
      clockFresh: false, samplesClockValidAtEvent: true, totalUncertaintyEstimateMs: 12,
      latestTargetMs: t, latestSentUpMs: t + 3, latestReceivedMs: t + 33,
      p50ErrorMs: 33, medianLatencyMs: 30, sampleCount: 1, matchedSendCount: 1});
    h.advance(180000);
    assert.equal(h.evaluate('clockUsable(clock)'), false);
    assert.equal(h.evaluate('applySummary(pastSummary)'), true);
    assert.equal(h.element('received-time').textContent, '18:30:00.033');
    assert.match(h.element('result-status').textContent, /样本接收时授时有效/);
    assert.match(h.element('result-status').textContent, /12\.000 ms/);
  });
  await check('页面离开前台使校时失效，仅 pointerup 避免合成 click 重复计数', () => {
    const h = harness(); h.setup();
    h.setVisibility('hidden'); h.listeners.get('document:visibilitychange')();
    assert.equal(h.get('clock'), null);
    assert.equal(h.listeners.has('pointerup'), true); assert.equal(h.listeners.has('click'), false);
  });
  await check('迟到400ms的单击能被记录，周期序列仍要求基线避免错拍', () => {
    const h = harness();
    assert.equal(h.evaluate('matchTarget(1400,[1000],new Set(),0,null).index'), 1);
    assert.equal(h.evaluate('matchTarget(1400,[1000,1200],new Set(),0,null)'), null);
    assert.equal(h.evaluate('matchTarget(1430,[1000,1200,1400],new Set([1]),0,30).index'), 3);
    assert.equal(h.evaluate('matchTarget(1030,[1000,1200],new Set([1]),0,30)'), null);
  });
  console.log('PhoneCalibrationPageTests: ' + passed + ' checks passed; deterministic page logic only, no real browser or phone input.');
})().catch(error => { console.error(error); process.exitCode = 1; });
