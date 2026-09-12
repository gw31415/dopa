// The schedule editor separates proposed values from the running deadline.
const MAX_DURATION_SECONDS = 24 * 60 * 60;

export function formatDuration(seconds) {
  const s = Math.max(0, Math.ceil(seconds));
  return [Math.floor(s / 3600), Math.floor(s / 60) % 60, s % 60]
    .map(value => String(value).padStart(2, '0')).join(':');
}
export function parseDuration(text) {
  const match = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(text.trim());
  if (!match) throw new Error('時間は「HH:MM:SS」で入力してください。');
  const [, h, m, s = '0'] = match;
  const seconds = Number(h) * 3600 + Number(m) * 60 + Number(s);
  if (Number(m) > 59 || Number(s) > 59 || seconds < 1 || seconds > 86400)
    throw new Error('時間は1秒から24時間の範囲で入力してください。');
  return seconds;
}
export function clockValue(timestamp) {
  const date = new Date(timestamp);
  return [date.getHours(), date.getMinutes(), date.getSeconds()]
    .map(value => String(value).padStart(2, '0')).join(':');
}
export function nextOccurrence(value, now) {
  const match = /^(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!match) throw new Error('終了時刻を入力してください。');
  const [, h, m, s = '0'] = match;
  if (+h > 23 || +m > 59 || +s > 59) throw new Error('終了時刻を確認してください。');
  const end = new Date(now);
  end.setHours(+h, +m, +s, 0);
  if (end.getTime() <= now) end.setDate(end.getDate() + 1);
  return end.getTime();
}
export function dayLabel(timestamp, now) {
  if (timestamp === null) return '';
  const end = new Date(timestamp);
  const today = new Date(now);
  if (end.toDateString() === today.toDateString()) return '今日';
  today.setDate(today.getDate() + 1);
  if (end.toDateString() === today.toDateString()) return '明日';
  return `${end.getMonth() + 1}/${end.getDate()}`;
}
export class Schedule {
  constructor() {
    this.running = false;
    this.deadline = null;
    this.config = {kind: 'duration', seconds: 3600};
    this.draft = null;
    this.rememberedSeconds = 3600;
  }
  target(now) {
    if (this.running) return this.deadline;
    return this.config.kind === 'end' ? this.config.end :
      this.config.seconds === null ? null : now + this.config.seconds * 1000;
  }
  editDuration(value, now = Date.now()) {
    const draft = {kind: 'duration', input: value};
    try { draft.seconds = parseDuration(value); }
    catch (error) {
      this.draft = {...draft, error: error.message};
      return;
    }
    if (this.running) {
      this.draft = draft;
      return;
    }
    this.config = {kind: 'duration', seconds: draft.seconds};
    this.draft = null;
  }
  editEnd(value, now) {
    const draft = {kind: 'end', input: value};
    try { draft.end = nextOccurrence(value, now); }
    catch (error) {
      this.draft = {...draft, error: error.message};
      return;
    }
    if (this.running) {
      this.draft = draft;
      return;
    }
    this.config = {kind: 'end', end: draft.end};
    this.draft = null;
  }
  proposedTarget(now) {
    if (!this.draft) return this.target(now);
    if (this.draft.error) return undefined;
    return this.draft.kind === 'end' ? this.draft.end :
      this.draft.seconds === null ? null : now + this.draft.seconds * 1000;
  }
  _addTimeSource(now) {
    if (this.draft) {
      if (this.draft.error) return null;
      if (this.draft.kind === 'duration') {
        if (this.draft.seconds === null) return {kind: 'duration', seconds: 0};
        if (Number.isInteger(this.draft.seconds) && this.draft.seconds >= 0 && this.draft.seconds <= MAX_DURATION_SECONDS) {
          return {kind: 'duration', seconds: this.draft.seconds};
        }
        return null;
      }
      if (this.draft.kind === 'end' && Number.isFinite(this.draft.end)) {
        return {kind: 'end', end: this.draft.end};
      }
      return null;
    }
    if (this.running) {
      if (this.deadline === null) return {kind: 'duration', seconds: 0};
      return Number.isFinite(this.deadline) ? {kind: 'end', end: this.deadline} : null;
    }
    if (this.config.kind === 'duration') {
      if (this.config.seconds === null) return {kind: 'duration', seconds: 0};
      return Number.isInteger(this.config.seconds) && this.config.seconds >= 0 && this.config.seconds <= MAX_DURATION_SECONDS
        ? {kind: 'duration', seconds: this.config.seconds}
        : null;
    }
    return this.config.kind === 'end' && Number.isFinite(this.config.end)
      ? {kind: 'end', end: this.config.end}
      : null;
  }
  _addTimePlan(seconds, now) {
    if (!Number.isFinite(now) || !Number.isInteger(seconds) || seconds <= 0) return null;
    const source = this._addTimeSource(now);
    if (!source) return null;
    if (source.kind === 'duration') {
      const nextSeconds = source.seconds + seconds;
      return Number.isSafeInteger(nextSeconds) && nextSeconds <= MAX_DURATION_SECONDS
        ? {kind: 'duration', input: formatDuration(nextSeconds), seconds: nextSeconds}
        : null;
    }
    if (source.end <= now) return null;
    const end = source.end + seconds * 1000;
    return Number.isFinite(end) && end > now && end - now <= MAX_DURATION_SECONDS * 1000
      ? {kind: 'end', input: clockValue(end), end}
      : null;
  }
  canAddTime(seconds, now) {
    return this._addTimePlan(seconds, now) !== null;
  }
  addTime(seconds, now) {
    const plan = this._addTimePlan(seconds, now);
    if (!plan) return false;
    this.draft = plan;
    this.confirm(now);
    return true;
  }
  _rememberFiniteTarget(now) {
    if (!Number.isFinite(now)) return;
    const proposed = this.proposedTarget(now);
    const target = proposed === undefined ? this.target(now) : proposed;
    if (!Number.isFinite(target) || target <= now) return;
    const seconds = Math.ceil((target - now) / 1000);
    if (seconds >= 1 && seconds <= MAX_DURATION_SECONDS) this.rememberedSeconds = seconds;
  }
  setUnlimited(enabled, now = Date.now()) {
    if (!Number.isFinite(now)) return;
    if (enabled) {
      this._rememberFiniteTarget(now);
      this.draft = null;
      this.config = {kind: 'duration', seconds: null};
      if (this.running) this.deadline = null;
      return;
    }
    if (this.config.kind !== 'duration' || this.config.seconds !== null) return;
    this.draft = null;
    this.config = {kind: 'duration', seconds: this.rememberedSeconds};
    if (this.running) this.deadline = now + this.rememberedSeconds * 1000;
  }
  confirm(now) {
    if (!this.draft) return;
    if (this.draft.error) throw new Error(this.draft.error);
    const end = this.proposedTarget(now);
    if (end !== null && end <= now) throw new Error('終了時刻が過ぎています。時刻を選び直してください。');
    this.config = this.draft.kind === 'end' ? {kind: 'end', end} :
      {kind: 'duration', seconds: this.draft.seconds};
    if (this.running) this.deadline = end;
    this.draft = null;
  }
  cancel() { this.draft = null; }
  start(now) {
    if (this.draft) throw new Error('変更を適用してください。');
    const end = this.target(now);
    if (end !== null && end <= now) throw new Error('終了時刻が過ぎています。時刻を選び直してください。');
    this.running = true;
    this.deadline = end;
  }
  stop() { this.running = false; this.deadline = null; this.draft = null; }
  tick(now) {
    if (this.running && this.deadline !== null && this.deadline <= now) {
      this.stop();
      return true;
    }
    return false;
  }
}
