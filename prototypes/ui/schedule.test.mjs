import test from 'node:test';
import assert from 'node:assert/strict';
import {Schedule, nextOccurrence, parseDuration, dayLabel} from './schedule.mjs';

const now = new Date(2026, 8, 12, 14, 0, 0).getTime();

test('editing a running duration keeps the deadline until confirmation', () => {
  const schedule = new Schedule();
  schedule.start(now);
  schedule.editDuration('00:30:00');
  assert.equal(schedule.deadline, now + 3600_000);
  schedule.confirm(now + 10_000);
  assert.equal(schedule.deadline, now + 10_000 + 1800_000);
  assert.equal(schedule.running, true);
});

test('valid duration and clock edits while stopped apply immediately', () => {
  const schedule = new Schedule();
  schedule.editDuration('00:30:00', now);
  assert.deepEqual(schedule.config, {kind: 'duration', seconds: 1800});
  assert.equal(schedule.draft, null);
  schedule.editEnd('14:30:00', now);
  assert.deepEqual(schedule.config, {kind: 'end', end: now + 1800_000});
  assert.equal(schedule.draft, null);
  schedule.start(now + 60_000);
  assert.equal(schedule.deadline, now + 1800_000);
});

test('cancel discards the edit while the original timer continues', () => {
  const schedule = new Schedule();
  schedule.start(now);
  schedule.editEnd('16:00:00', now);
  schedule.cancel();
  assert.equal(schedule.target(now + 10_000), now + 3600_000);
  assert.equal(schedule.draft, null);
});

test('an old deadline can expire while a new duration is still unconfirmed', () => {
  const schedule = new Schedule();
  schedule.start(now);
  schedule.editDuration('02:00:00');
  assert.equal(schedule.tick(now + 3600_000), true);
  assert.equal(schedule.running, false);
  assert.equal(schedule.draft, null);
});

test('a past clock choice is visibly assigned to tomorrow', () => {
  const end = nextOccurrence('13:00:00', now);
  assert.equal(end, new Date(2026, 8, 13, 13, 0, 0).getTime());
  assert.equal(dayLabel(end, now), '明日');
});

test('clock drafts that expire before confirmation cannot silently roll forward', () => {
  const schedule = new Schedule();
  schedule.start(now);
  schedule.editEnd('14:00:01', now);
  assert.throws(() => schedule.confirm(now + 2000), /終了時刻が過ぎています/);
  assert.equal(schedule.deadline, now + 3600_000);
});

test('invalid values cannot change the applied deadline', () => {
  const schedule = new Schedule();
  schedule.start(now);
  for (const text of ['', '00:00:00', '00:60:00', '25:00:00', '1 hour']) {
    schedule.editDuration(text);
    assert.throws(() => schedule.confirm(now));
    assert.equal(schedule.deadline, now + 3600_000);
  }
  assert.throws(() => nextOccurrence('24:00', now));
  assert.throws(() => parseDuration('手動'), /HH:MM:SS/);
  assert.equal(parseDuration('24:00:00'), 86400);
});

test('unlimited mode applies immediately while running', () => {
  const schedule = new Schedule();
  schedule.start(now);
  schedule.setUnlimited(true, now);
  assert.equal(schedule.deadline, null);
  assert.deepEqual(schedule.config, {kind: 'duration', seconds: null});
  assert.equal(schedule.draft, null);
  assert.equal(schedule.running, true);
  assert.equal(schedule.tick(now + 86400_000), false);
  assert.equal(schedule.running, true);
});

test('invalid stopped edits preserve config until a correction is entered', () => {
  const schedule = new Schedule();
  schedule.editDuration('壊れた入力', now);
  const invalidDurationDraft = schedule.draft;
  assert.equal(schedule.draft.error !== undefined, true);
  assert.deepEqual(schedule.config, {kind: 'duration', seconds: 3600});
  assert.throws(() => schedule.start(now), /変更を適用してください/);
  schedule.editDuration('00:30:00', now);
  assert.equal(schedule.draft, null);
  assert.deepEqual(schedule.config, {kind: 'duration', seconds: 1800});
  assert.notEqual(schedule.draft, invalidDurationDraft);

  schedule.editEnd('invalid', now);
  const invalidEndDraft = schedule.draft;
  assert.equal(schedule.draft.error !== undefined, true);
  assert.deepEqual(schedule.config, {kind: 'duration', seconds: 1800});
  schedule.editEnd('14:45:00', now);
  assert.equal(schedule.draft, null);
  assert.deepEqual(schedule.config, {kind: 'end', end: now + 2700_000});
  assert.notEqual(schedule.draft, invalidEndDraft);
});

test('duration additions apply immediately and accumulate in config', () => {
  const schedule = new Schedule();
  assert.equal(schedule.addTime(900, now), true);
  assert.equal(schedule.draft, null);
  assert.equal(schedule.config.seconds, 4500);
  assert.equal(schedule.addTime(1800, now), true);
  assert.equal(schedule.config.seconds, 6300);
  assert.equal(schedule.draft, null);
});

test('absolute additions update a running deadline immediately and accumulate', () => {
  const schedule = new Schedule();
  schedule.start(now);
  const originalDeadline = schedule.deadline;
  assert.equal(schedule.addTime(900, now), true);
  assert.equal(schedule.draft, null);
  assert.equal(schedule.deadline, originalDeadline + 900_000);
  assert.deepEqual(schedule.config, {kind: 'end', end: originalDeadline + 900_000});
  assert.equal(schedule.addTime(1800, now + 120_000), true);
  assert.equal(schedule.deadline, originalDeadline + 2700_000);
  assert.equal(schedule.draft, null);
});

test('adding to a stopped absolute config applies immediately', () => {
  const schedule = new Schedule();
  schedule.editEnd('14:30:00', now);
  assert.equal(schedule.addTime(900, now), true);
  assert.deepEqual(schedule.config, {kind: 'end', end: now + 2700_000});
  assert.equal(schedule.draft, null);
});

test('a running duration draft is combined by a pill and applied immediately', () => {
  const schedule = new Schedule();
  schedule.start(now);
  schedule.editDuration('00:30:00', now);
  assert.equal(schedule.addTime(900, now), true);
  assert.deepEqual(schedule.config, {kind: 'duration', seconds: 2700});
  assert.equal(schedule.deadline, now + 2700_000);
  assert.equal(schedule.draft, null);
});

test('unlimited mode changes to a finite duration immediately when adding time', () => {
  const stopped = new Schedule();
  stopped.setUnlimited(true, now);
  assert.deepEqual(stopped.config, {kind: 'duration', seconds: null});
  assert.equal(stopped.addTime(900, now), true);
  assert.deepEqual(stopped.config, {kind: 'duration', seconds: 900});
  assert.equal(stopped.draft, null);

  const running = new Schedule();
  running.start(now);
  running.setUnlimited(true, now);
  assert.equal(running.deadline, null);
  assert.equal(running.running, true);
  assert.equal(running.addTime(900, now), true);
  assert.deepEqual(running.config, {kind: 'duration', seconds: 900});
  assert.equal(running.deadline, now + 900_000);
  assert.equal(running.draft, null);
});

test('unlimited mode restores the remembered finite duration and keeps running state', () => {
  const stopped = new Schedule();
  stopped.editDuration('00:45:00', now);
  stopped.setUnlimited(true, now);
  assert.equal(stopped.rememberedSeconds, 2700);
  stopped.setUnlimited(false, now + 120_000);
  assert.deepEqual(stopped.config, {kind: 'duration', seconds: 2700});
  assert.equal(stopped.draft, null);

  const running = new Schedule();
  running.start(now);
  running.setUnlimited(true, now + 120_000);
  assert.equal(running.rememberedSeconds, 3480);
  assert.equal(running.deadline, null);
  running.setUnlimited(false, now + 180_000);
  assert.deepEqual(running.config, {kind: 'duration', seconds: 3480});
  assert.equal(running.deadline, now + 180_000 + 3480_000);
  assert.equal(running.running, true);
});

test('reselecting unlimited preserves remembered time and clears invalid drafts', () => {
  const schedule = new Schedule();
  schedule.setUnlimited(true, now);
  assert.equal(schedule.rememberedSeconds, 3600);
  schedule.setUnlimited(true, now + 120_000);
  assert.equal(schedule.rememberedSeconds, 3600);

  schedule.editDuration('壊れた入力', now);
  assert.notEqual(schedule.draft, null);
  schedule.setUnlimited(true, now + 240_000);
  assert.equal(schedule.draft, null);
  assert.equal(schedule.config.seconds, null);
  assert.equal(schedule.rememberedSeconds, 3600);
});

test('unlimited can be enabled with an invalid running draft without losing the old deadline', () => {
  const schedule = new Schedule();
  schedule.start(now);
  schedule.editDuration('壊れた入力', now);
  schedule.setUnlimited(true, now + 120_000);
  assert.equal(schedule.rememberedSeconds, 3480);
  assert.equal(schedule.deadline, null);
  assert.equal(schedule.draft, null);
  assert.equal(schedule.running, true);
});

test('invalid, expired, and over-limit additions leave the applied state untouched', () => {
  const schedule = new Schedule();
  schedule.editDuration('壊れた入力', now);
  const invalidDraft = schedule.draft;
  assert.equal(schedule.canAddTime(900, now), false);
  assert.equal(schedule.addTime(900, now), false);
  assert.equal(schedule.draft, invalidDraft);
  assert.deepEqual(schedule.config, {kind: 'duration', seconds: 3600});

  schedule.draft = null;
  schedule.start(now);
  const originalDeadline = schedule.deadline;
  schedule.deadline = now - 1;
  assert.equal(schedule.canAddTime(900, now), false);
  assert.equal(schedule.addTime(900, now), false);
  assert.equal(schedule.deadline, now - 1);
  assert.equal(schedule.config.seconds, 3600);

  schedule.stop();
  schedule.editDuration('24:00:00', now);
  assert.equal(schedule.draft, null);
  const fullConfig = schedule.config;
  assert.equal(schedule.canAddTime(1, now), false);
  assert.equal(schedule.addTime(1, now), false);
  assert.deepEqual(schedule.config, fullConfig);
  assert.equal(schedule.deadline, null);
});
