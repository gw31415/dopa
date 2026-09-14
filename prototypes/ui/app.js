'use strict';
import {Schedule, formatDuration, clockValue, dayLabel} from './schedule.mjs';
import {createValidationPopover} from './validation-popover.mjs';

// Local interaction fixtures only; this preview never connects to the daemon.
const $ = selector => document.querySelector(selector);
const schedule = new Schedule();
const duration = $('#duration');
const endTime = $('#end-time');
const incrementButtons = [...document.querySelectorAll('[data-add-seconds]')];
const validationPopover = createValidationPopover($('#validation-popover'), [duration, endTime]);
let tab = 'own';
let pendingStop = [];
let localError = '';
const query = new URLSearchParams(location.search);
const cliCount = (() => {
  const value = query.get('cli');
  if (value === null || value.trim() === '') return 1;
  const parsed = Number(value);
  return Number.isInteger(parsed) ? Math.min(50, Math.max(0, parsed)) : 1;
})();
let cliSessions = Array.from({length: cliCount}, (_, index) => ({
  id: `cli-${4281 + index}`,
  pid: 4281 + index,
}));
if (query.get('state') === 'running') {
  schedule.start(Date.now());
  schedule.deadline = Date.now() + (47 * 60 + 23) * 1000;
}
if (query.get('tab') === 'global') tab = 'global';

function renderTime(now) {
  const proposedTarget = schedule.proposedTarget(now);
  const invalidKind = proposedTarget === undefined ? schedule.draft?.kind : null;
  const target = proposedTarget === undefined ? schedule.target(now) : proposedTarget;
  const unlimited = target === null;
  const focused = document.activeElement;
  if (target !== undefined) {
    if (focused !== duration && invalidKind !== 'duration') {
      duration.value = unlimited ? '' : formatDuration((target - now) / 1000);
    }
    if (focused !== endTime && invalidKind !== 'end') endTime.value = target === null ? '' : clockValue(target);
    $('#end-day').textContent = dayLabel(target, now);
    $('#end-day').hidden = target === null;
  }
  duration.disabled = unlimited;
  endTime.disabled = unlimited;
  $('#unlimited').checked = unlimited;
  $('#duration-label').textContent = schedule.running && !schedule.draft && !unlimited ? '残り時間' : '時間';
  const error = schedule.draft?.error || localError;
  const needsConfirmation = schedule.running && !!schedule.draft;
  $('#power-button').hidden = needsConfirmation;
  $('#power-button').disabled = !!schedule.draft;
  $('#cancel-edit').hidden = !needsConfirmation;
  $('#cancel-edit').disabled = !needsConfirmation;
  $('#confirm-edit').hidden = !needsConfirmation || !!error;
  $('#confirm-edit').disabled = !needsConfirmation || !!error;
  for (const button of incrementButtons) button.disabled = !schedule.canAddTime(Number(button.dataset.addSeconds), now);
  const errorInput = error ? ((schedule.draft?.kind === 'end' || (!schedule.draft && schedule.config.kind === 'end')) ? endTime : duration) : null;
  for (const input of [duration, endTime]) {
    input.setAttribute('aria-invalid', input === errorInput);
    if (input === errorInput) input.setAttribute('aria-describedby', 'edit-error');
    else input.removeAttribute('aria-describedby');
  }
  validationPopover.update({
    anchor: errorInput,
    title: errorInput === endTime ? '終了時刻を確認してください' : '時間を確認してください',
    message: error,
    key: error ? `${errorInput.id}:${schedule.draft?.input ?? ''}:${error}` : '',
    visible: !!error && tab === 'own' && !$('#stop-dialog').open,
  });
}
function renderSessions() {
  const rows = [];
  if (schedule.running) rows.push({id: 'own', name: 'Dopa', subtitle: 'このアプリ'});
  rows.push(...cliSessions.map(session => ({
    id: session.id,
    name: 'dopa CLI',
    subtitle: `PID ${session.pid}`,
  })));
  $('#session-count').textContent = String(rows.length);
  $('#sessions').innerHTML = rows.length ? rows.map(({id, name, subtitle}) =>
    `<div class="setting-row session-row" data-session="${id}"><div><strong>${name}</strong><small>${subtitle}</small></div><button class="session-stop" aria-label="${name}${id === 'own' ? '' : ` (${subtitle})`}のスリープ防止を停止">停止</button></div>`).join('') :
    '<p class="empty-state">スリープ防止は実行されていません</p>';
  $('#stop-all').disabled = rows.length === 0;
}
function render() {
  $('#own-panel').hidden = tab !== 'own';
  $('#global-panel').hidden = tab !== 'global';
  for (const name of ['own', 'global']) {
    $(`#${name}-panel`).inert = name !== tab;
    $(`#tab-${name}`).setAttribute('aria-selected', name === tab);
    $(`#tab-${name}`).tabIndex = name === tab ? 0 : -1;
  }
  const status = schedule.running ? 'own' : cliSessions.length > 0 ? 'other' : 'inactive';
  const statusLabel = {
    own: 'スリープ防止中',
    other: '他のアプリやCLIが動作中',
    inactive: 'オフ',
  }[status];
  $('#status').dataset.state = status;
  if ($('#status-label').textContent !== statusLabel) $('#status-label').textContent = statusLabel;
  $('#power-button').textContent = schedule.running ? '停止' : '開始';
  $('#power-button').classList.toggle('stop', schedule.running);
  renderTime(Date.now());
  renderSessions();
}
for (const name of ['own', 'global']) {
  $(`#tab-${name}`).addEventListener('click', () => { tab = name; render(); });
  $(`#tab-${name}`).addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    tab = event.key === 'Home' ? 'own' : event.key === 'End' ? 'global' : tab === 'own' ? 'global' : 'own';
    render();
    $(`#tab-${tab}`).focus();
  });
}
for (const id of ['display-switch', 'lid-switch']) {
  $(`#${id}`).addEventListener('click', event => {
    const toggle = event.currentTarget;
    toggle.setAttribute('aria-checked', String(toggle.getAttribute('aria-checked') !== 'true'));
  });
}
duration.addEventListener('input', () => {
  localError = '';
  schedule.editDuration(duration.value, Date.now());
  render();
});
endTime.addEventListener('input', () => {
  localError = '';
  schedule.editEnd(endTime.value, Date.now());
  render();
});
$('#unlimited').addEventListener('change', event => {
  schedule.setUnlimited(event.currentTarget.checked, Date.now());
  localError = '';
  releaseInputFocus();
  render();
});
for (const button of incrementButtons) {
  button.addEventListener('click', () => {
    if (!schedule.addTime(Number(button.dataset.addSeconds), Date.now())) return;
    localError = '';
    releaseInputFocus();
    render();
    if (button.disabled) duration.focus({preventScroll: true});
  });
}
function releaseInputFocus() {
  if (document.activeElement === duration || document.activeElement === endTime) document.activeElement.blur();
}
$('#cancel-edit').addEventListener('click', () => {
  schedule.cancel(); localError = ''; releaseInputFocus(); render();
  $('#power-button').focus({preventScroll: true});
});
$('#controls').addEventListener('submit', event => {
  event.preventDefault();
  if (!schedule.running || !schedule.draft) return;
  try { schedule.confirm(Date.now()); localError = ''; releaseInputFocus(); }
  catch (error) { localError = error.message; }
  render();
  if (!schedule.draft) $('#power-button').focus({preventScroll: true});
});
$('#power-button').addEventListener('click', () => {
  if (schedule.draft) return;
  try {
    if (schedule.running) schedule.stop(); else schedule.start(Date.now());
    localError = ''; releaseInputFocus();
  } catch (error) { localError = error.message; }
  render();
});
function stopSessions(targets) {
  const list = $('#sessions');
  const scrollTop = list.scrollTop;
  const rows = [...list.querySelectorAll('[data-session]')];
  const stoppedIndex = rows.findIndex(row => targets.includes(row.dataset.session));
  if (targets.includes('own')) schedule.stop();
  const cliTargets = new Set(targets.filter(id => id.startsWith('cli-')));
  if (cliTargets.size) cliSessions = cliSessions.filter(session => !cliTargets.has(session.id));
  localError = '';
  render();
  list.scrollTop = scrollTop;
  const buttons = list.querySelectorAll('.session-stop');
  (buttons[Math.min(Math.max(stoppedIndex, 0), buttons.length - 1)] || $('#tab-global')).focus({preventScroll: true});
}
function cliTargetIds(targets) {
  return targets.filter(id => id.startsWith('cli-'));
}
function openStopDialog(targets, all = false) {
  pendingStop = targets;
  $('#stop-title').textContent = all ? `${targets.length}件のスリープ防止を停止しますか？` : 'CLIのスリープ防止を停止しますか？';
  if (all) {
    const cliTargets = cliTargetIds(targets);
    const source = cliTargets.length ? (targets.includes('own') ? 'CLIから開始したものも停止します。' : 'CLIのスリープ防止を停止します。') : 'このアプリのスリープ防止を停止します。';
    $('#stop-description').textContent = `${source}DopaはMacのスリープを防止しなくなります。`;
  } else {
    const remainingCliCount = cliSessions.length - cliTargetIds(targets).length;
    const remaining = [];
    if (remainingCliCount > 0) remaining.push(remainingCliCount === 1 ? 'ほかのCLI' : `ほかの${remainingCliCount}件のCLI`);
    if (schedule.running) remaining.push('このアプリ');
    $('#stop-description').textContent = remaining.length
      ? `このCLIのスリープ防止を停止します。${remaining.join('と')}のスリープ防止は継続します。`
      : 'DopaはMacのスリープを防止しなくなります。';
  }
  $('#stop-targets').textContent = targets.map(id => {
    if (id === 'own') return 'Dopa（このアプリ）';
    const session = cliSessions.find(item => item.id === id);
    return session ? `dopa CLI (PID ${session.pid})` : 'dopa CLI';
  }).join('\n');
  $('#confirm-stop').textContent = all ? 'すべて停止' : 'スリープ防止を停止';
  $('#stop-dialog').showModal();
  $('#cancel-stop').focus();
}
$('#sessions').addEventListener('click', event => {
  const button = event.target.closest('.session-stop');
  if (!button) return;
  const target = button.closest('[data-session]');
  if (target.dataset.session === 'own') stopSessions(['own']);
  else openStopDialog([target.dataset.session]);
});
$('#stop-all').addEventListener('click', () => {
  const targets = [schedule.running && 'own', ...cliSessions.map(session => session.id)].filter(Boolean);
  if (targets.length) openStopDialog(targets, true);
});
$('#cancel-stop').addEventListener('click', () => $('#stop-dialog').close());
$('#stop-dialog').addEventListener('close', () => { pendingStop = []; });
$('#confirm-stop').addEventListener('click', () => {
  const targets = pendingStop;
  $('#stop-dialog').close();
  stopSessions(targets);
});
setInterval(() => {
  if (schedule.tick(Date.now())) {
    localError = '';
    if ($('#stop-dialog').open) $('#stop-dialog').close();
    releaseInputFocus();
    render();
  } else renderTime(Date.now());
}, 1000);
render();
