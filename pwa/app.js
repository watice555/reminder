const DB_NAME = 'cycle-reminder-db';
const DB_VERSION = 1;
const TASK_STORE = 'tasks';
const SNAPSHOT_KEY = 'cycle-reminder.snapshot.v1';
const { DEFAULT_INTERVAL_HOURS } = ReminderModel;

/** @type {Array<ReminderTask>} */
let tasks = [];
let db = null;
let editingTaskId = null;
let deferredInstallPrompt = null;
let activeView = 'tasks';
const completingTaskIds = new Set();

/**
 * @typedef {Object} ReminderTask
 * @property {string} id
 * @property {string} name
 * @property {number} intervalHours
 * @property {string} lastCompletedAt
 * @property {string} nextDueAt
 * @property {string} createdAt
 * @property {Array<CompletionRecord>} completions
 */

/**
 * @typedef {Object} CompletionRecord
 * @property {string} id
 * @property {string} completedAt
 * @property {string} scheduledDueAt
 * @property {number} intervalHours
 */

const elements = {
  summary: document.querySelector('#summary'),
  taskList: document.querySelector('#taskList'),
  taskTemplate: document.querySelector('#taskTemplate'),
  newTaskButton: document.querySelector('#newTaskButton'),
  exportButton: document.querySelector('#exportButton'),
  importButton: document.querySelector('#importButton'),
  installButton: document.querySelector('#installButton'),
  storageNotice: document.querySelector('#storageNotice'),
  taskDialog: document.querySelector('#taskDialog'),
  taskForm: document.querySelector('#taskForm'),
  taskDialogTitle: document.querySelector('#taskDialogTitle'),
  taskNameInput: document.querySelector('#taskNameInput'),
  intervalDaysInput: document.querySelector('#intervalDaysInput'),
  intervalHoursInput: document.querySelector('#intervalHoursInput'),
  cancelTaskButton: document.querySelector('#cancelTaskButton'),
  dataDialog: document.querySelector('#dataDialog'),
  dataDialogTitle: document.querySelector('#dataDialogTitle'),
  dataText: document.querySelector('#dataText'),
  closeDataButton: document.querySelector('#closeDataButton'),
  confirmImportButton: document.querySelector('#confirmImportButton'),
  taskViewTab: document.querySelector('#taskViewTab'),
  statisticsViewTab: document.querySelector('#statisticsViewTab'),
  taskView: document.querySelector('#taskView'),
  statisticsView: document.querySelector('#statisticsView'),
  statisticsToday: document.querySelector('#statisticsToday'),
  statisticsSevenDays: document.querySelector('#statisticsSevenDays'),
  statisticsTotal: document.querySelector('#statisticsTotal'),
  statisticsOnTime: document.querySelector('#statisticsOnTime'),
  statisticsHint: document.querySelector('#statisticsHint'),
  statisticsChart: document.querySelector('#statisticsChart'),
  statisticsRanking: document.querySelector('#statisticsRanking'),
};

init();

async function init() {
  bindEvents();
  registerServiceWorker();
  await prepareStorage();
  tasks = await loadTasks();
  await persistTasks(tasks);
  render();
  setInterval(render, 30_000);
}

function bindEvents() {
  elements.newTaskButton.addEventListener('click', () => openTaskDialog());
  elements.cancelTaskButton.addEventListener('click', closeTaskDialog);
  elements.taskForm.addEventListener('submit', handleTaskSubmit);
  elements.exportButton.addEventListener('click', openExportDialog);
  elements.importButton.addEventListener('click', openImportDialog);
  elements.closeDataButton.addEventListener('click', closeDataDialog);
  elements.confirmImportButton.addEventListener('click', handleImport);
  elements.installButton.addEventListener('click', handleInstall);
  elements.taskViewTab.addEventListener('click', () => switchView('tasks'));
  elements.statisticsViewTab.addEventListener('click', () => switchView('statistics'));

  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault();
    deferredInstallPrompt = event;
    elements.installButton.hidden = false;
  });
}

function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) {
    showStorageNotice('当前浏览器不支持离线缓存。任务仍会保存，但离线打开可能不可用。');
    return;
  }

  let refreshing = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (refreshing) {
      return;
    }

    refreshing = true;
    window.location.reload();
  });

  navigator.serviceWorker
    .register('./sw.js', { updateViaCache: 'none' })
    .then((registration) => {
      registration.update();

      if (registration.waiting) {
        registration.waiting.postMessage({ type: 'SKIP_WAITING' });
      }

      registration.addEventListener('updatefound', () => {
        const installingWorker = registration.installing;
        if (!installingWorker) {
          return;
        }

        installingWorker.addEventListener('statechange', () => {
          if (installingWorker.state === 'installed' && navigator.serviceWorker.controller) {
            installingWorker.postMessage({ type: 'SKIP_WAITING' });
          }
        });
      });
    })
    .catch(() => {
      showStorageNotice('离线缓存注册失败。任务仍会保存，但离线打开可能不可用。');
    });
}

async function prepareStorage() {
  if (navigator.storage?.persist) {
    try {
      const persisted = await navigator.storage.persisted();
      if (!persisted) {
        await navigator.storage.persist();
      }
    } catch {
      // Some iOS versions expose partial StorageManager behavior.
    }
  }

  try {
    db = await openDatabase();
  } catch {
    db = null;
    showStorageNotice('IndexedDB 不可用，已改用浏览器快照保存。建议经常导出 JSON 备份。');
  }
}

function openDatabase() {
  return new Promise((resolve, reject) => {
    if (!('indexedDB' in window)) {
      reject(new Error('IndexedDB unavailable'));
      return;
    }

    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(TASK_STORE)) {
        database.createObjectStore(TASK_STORE, { keyPath: 'id' });
      }
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function loadTasks() {
  if (db) {
    try {
      const storedTasks = await getAllTasksFromDb();
      if (storedTasks.length) {
        const normalizedTasks = ReminderModel.normalizeTasks(storedTasks);
        writeSnapshot(normalizedTasks);
        return normalizedTasks;
      }
    } catch {
      showStorageNotice('IndexedDB 读取失败，正在尝试从本地快照恢复。');
    }
  }

  return ReminderModel.normalizeTasks(readSnapshot());
}

function getAllTasksFromDb() {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(TASK_STORE, 'readonly');
    const store = tx.objectStore(TASK_STORE);
    const request = store.getAll();

    request.onsuccess = () => resolve(request.result || []);
    request.onerror = () => reject(request.error);
  });
}

async function persistTasks(nextTasks) {
  writeSnapshot(nextTasks);

  if (!db) {
    return;
  }

  await new Promise((resolve, reject) => {
    const tx = db.transaction(TASK_STORE, 'readwrite');
    const store = tx.objectStore(TASK_STORE);
    store.clear();
    nextTasks.forEach((task) => store.put(task));
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  }).catch(() => {
    showStorageNotice('IndexedDB 写入失败，但最近快照已保存。建议导出 JSON 备份。');
  });
}

function writeSnapshot(nextTasks) {
  try {
    localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(nextTasks));
  } catch {
    showStorageNotice('浏览器快照写入失败。请尽快导出 JSON 备份。');
  }
}

function readSnapshot() {
  try {
    const raw = localStorage.getItem(SNAPSHOT_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

async function handleTaskSubmit(event) {
  event.preventDefault();

  const name = elements.taskNameInput.value.trim();
  const intervalHours = parseFormInterval();

  if (!name) {
    alert('请输入任务名称。');
    return;
  }

  if (intervalHours === null) {
    alert('请输入大于 0 的循环时间。天和小时都可以不填，不填按 0 计算。');
    return;
  }

  if (editingTaskId) {
    tasks = tasks.map((task) => {
      if (task.id !== editingTaskId) {
        return task;
      }

      return {
        ...task,
        name,
        intervalHours,
        nextDueAt: addHours(new Date(task.lastCompletedAt), intervalHours).toISOString(),
      };
    });
  } else {
    const completedAt = new Date();
    tasks = [
      {
        id: createId(),
        name,
        intervalHours,
        lastCompletedAt: completedAt.toISOString(),
        nextDueAt: addHours(completedAt, intervalHours).toISOString(),
        createdAt: completedAt.toISOString(),
        completions: [],
      },
      ...tasks,
    ];
  }

  await persistTasks(tasks);
  closeTaskDialog();
  render();
}

async function completeTask(taskId) {
  if (completingTaskIds.has(taskId)) {
    return;
  }

  completingTaskIds.add(taskId);
  const completedAt = new Date();
  tasks = tasks.map((task) => {
    if (task.id !== taskId) {
      return task;
    }

    return ReminderModel.completeTask(task, completedAt) || task;
  });

  render();
  try {
    await persistTasks(tasks);
  } finally {
    completingTaskIds.delete(taskId);
    render();
  }
}

async function deleteTask(taskId) {
  const task = tasks.find((item) => item.id === taskId);
  const completionCount = task?.completions?.length || 0;
  const historyNotice = completionCount
    ? `，并删除它的 ${completionCount} 条完成记录`
    : '';
  if (!confirm(`确定删除“${task?.name || '这个任务'}”${historyNotice}吗？`)) {
    return;
  }

  tasks = tasks.filter((item) => item.id !== taskId);
  await persistTasks(tasks);
  render();
}

function openTaskDialog(task = null) {
  editingTaskId = task?.id || null;
  elements.taskDialogTitle.textContent = task ? '编辑任务' : '新增任务';
  elements.taskNameInput.value = task?.name || '';
  setIntervalInputs(task?.intervalHours || DEFAULT_INTERVAL_HOURS);
  elements.taskDialog.showModal();
  setTimeout(() => elements.taskNameInput.focus(), 50);
}

function closeTaskDialog() {
  editingTaskId = null;
  elements.taskForm.reset();
  setIntervalInputs(DEFAULT_INTERVAL_HOURS);
  elements.taskDialog.close();
}

function openExportDialog() {
  elements.dataDialogTitle.textContent = '导出 JSON';
  elements.dataText.value = JSON.stringify(ReminderModel.createBackup(tasks), null, 2);
  elements.dataText.readOnly = true;
  elements.confirmImportButton.hidden = true;
  elements.dataDialog.showModal();
  elements.dataText.focus();
  elements.dataText.select();
}

function openImportDialog() {
  elements.dataDialogTitle.textContent = '导入 JSON';
  elements.dataText.value = '';
  elements.dataText.readOnly = false;
  elements.dataText.placeholder = '粘贴之前导出的任务 JSON';
  elements.confirmImportButton.hidden = false;
  elements.dataDialog.showModal();
  elements.dataText.focus();
}

function closeDataDialog() {
  elements.dataDialog.close();
}

async function handleImport() {
  try {
    const backup = ReminderModel.parseBackup(elements.dataText.value);
    if (
      !confirm(
        `将用 ${backup.tasks.length} 个任务和 ${backup.completionCount} 条完成记录替换当前数据，确定继续吗？`,
      )
    ) {
      return;
    }

    tasks = backup.tasks;
    await persistTasks(tasks);
    closeDataDialog();
    render();
  } catch (error) {
    alert(error instanceof Error ? error.message : '请输入有效的 JSON。');
  }
}

async function handleInstall() {
  if (!deferredInstallPrompt) {
    return;
  }

  deferredInstallPrompt.prompt();
  await deferredInstallPrompt.userChoice;
  deferredInstallPrompt = null;
  elements.installButton.hidden = true;
}

function render() {
  const now = Date.now();
  renderHeader();
  renderTaskList(now);
  renderStatistics(now);
}

function renderHeader() {
  const isTaskView = activeView === 'tasks';
  elements.summary.textContent = isTaskView
    ? `${tasks.length} 个任务保存在本机`
    : '完成记录保存在每个任务中';
  elements.newTaskButton.hidden = !isTaskView;
  elements.taskView.hidden = !isTaskView;
  elements.statisticsView.hidden = isTaskView;
  elements.taskViewTab.classList.toggle('is-active', isTaskView);
  elements.statisticsViewTab.classList.toggle('is-active', !isTaskView);
  elements.taskViewTab.setAttribute('aria-selected', String(isTaskView));
  elements.statisticsViewTab.setAttribute('aria-selected', String(!isTaskView));
}

function renderTaskList(now) {
  const sortedTasks = [...tasks].sort(
    (a, b) => new Date(a.nextDueAt).getTime() - new Date(b.nextDueAt).getTime(),
  );

  elements.taskList.textContent = '';

  if (!sortedTasks.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-state';
    empty.innerHTML = '<strong>还没有任务</strong><span>新增一个任务，例如“换滤芯”，设置 2 天循环。</span>';
    elements.taskList.append(empty);
    return;
  }

  sortedTasks.forEach((task) => {
    const card = elements.taskTemplate.content.firstElementChild.cloneNode(true);
    const remainingMs = new Date(task.nextDueAt).getTime() - now;
    const isOverdue = remainingMs <= 0;
    const progress = getCycleProgress(task, now);
    const progressPercent = Math.round(progress * 100);

    card.classList.toggle('is-overdue', isOverdue);
    card.querySelector('.task-name').textContent = task.name;
    card.querySelector('.task-cycle').textContent = `${formatInterval(task.intervalHours)}循环`;
    card.querySelector('.task-status').textContent = isOverdue ? '已到期' : '进行中';
    card.querySelector('.task-status').classList.toggle('is-active', !isOverdue);
    card.querySelector('.task-status').classList.toggle('is-overdue', isOverdue);
    card.querySelector('.task-remaining').textContent = isOverdue
      ? `超时 ${formatDuration(Math.abs(remainingMs))}`
      : `剩余 ${formatDuration(remainingMs)}`;
    card.querySelector('.task-due').textContent = `下次到期：${formatDateTime(task.nextDueAt)}`;
    card.querySelector('.task-completed').textContent = `上次完成：${formatDateTime(task.lastCompletedAt)}`;
    card.querySelector('.task-completion-count').textContent = `累计完成 ${task.completions.length} 次`;
    card.querySelector('.task-progress').setAttribute('aria-label', `当前循环已过去 ${progressPercent}%`);
    card.querySelector('.task-progress__value').textContent = `已过去 ${progressPercent}%`;
    card.querySelector('.task-progress__fill').style.width = `${progressPercent}%`;
    const doneButton = card.querySelector('.done-button');
    const isCompleting = completingTaskIds.has(task.id);
    doneButton.disabled = isCompleting;
    doneButton.textContent = isCompleting ? '正在保存…' : '完成并重置';
    doneButton.addEventListener('click', () => completeTask(task.id));
    card.querySelector('.edit-button').addEventListener('click', () => openTaskDialog(task));
    card.querySelector('.delete-button').addEventListener('click', () => deleteTask(task.id));

    elements.taskList.append(card);
  });
}

function renderStatistics(now) {
  const statistics = ReminderModel.calculateStatistics(tasks, now);
  elements.statisticsToday.textContent = String(statistics.today);
  elements.statisticsSevenDays.textContent = String(statistics.lastSevenDays);
  elements.statisticsTotal.textContent = String(statistics.total);
  elements.statisticsOnTime.textContent =
    statistics.onTimeRate === null ? '—' : `${Math.round(statistics.onTimeRate * 100)}%`;
  elements.statisticsHint.textContent = statistics.total
    ? `共记录 ${statistics.total} 次完成，准时 ${statistics.onTimeCount} 次。`
    : '统计从本次升级后开始；旧任务的当前周期会保留，但不会伪造历史完成次数。';

  const maxDailyCount = Math.max(1, ...statistics.daily.map((item) => item.count));
  elements.statisticsChart.textContent = '';
  statistics.daily.forEach((item) => {
    const column = document.createElement('div');
    column.className = 'chart-column';
    column.setAttribute('aria-label', `${item.label} 完成 ${item.count} 次`);

    const count = document.createElement('strong');
    count.textContent = String(item.count);
    const track = document.createElement('div');
    track.className = 'chart-track';
    const bar = document.createElement('div');
    bar.className = 'chart-bar';
    bar.style.height = `${Math.max(item.count ? 10 : 2, (item.count / maxDailyCount) * 100)}%`;
    const label = document.createElement('span');
    label.textContent = item.label;

    track.append(bar);
    column.append(count, track, label);
    elements.statisticsChart.append(column);
  });

  elements.statisticsRanking.textContent = '';
  if (!statistics.taskRanking.length) {
    const empty = document.createElement('p');
    empty.className = 'statistics-empty';
    empty.textContent = '完成一次任务后，这里会显示任务排行。';
    elements.statisticsRanking.append(empty);
    return;
  }

  statistics.taskRanking.forEach((item, index) => {
    const row = document.createElement('div');
    row.className = 'ranking-row';
    const main = document.createElement('div');
    const name = document.createElement('strong');
    name.textContent = `${index + 1}. ${item.name}`;
    const detail = document.createElement('span');
    detail.textContent = item.latestCompletedAt
      ? `最近完成 ${formatDateTime(item.latestCompletedAt)}`
      : '暂无完成记录';
    const result = document.createElement('div');
    result.className = 'ranking-result';
    const total = document.createElement('strong');
    total.textContent = `${item.total} 次`;
    const rate = document.createElement('span');
    rate.textContent = item.onTimeRate === null ? '暂无准时率' : `准时 ${Math.round(item.onTimeRate * 100)}%`;

    main.append(name, detail);
    result.append(total, rate);
    row.append(main, result);
    elements.statisticsRanking.append(row);
  });
}

function switchView(view) {
  activeView = view === 'statistics' ? 'statistics' : 'tasks';
  render();
}

function addHours(date, hours) {
  return new Date(date.getTime() + hours * 60 * 60 * 1000);
}

function parseFormInterval() {
  const days = parseOptionalNumber(elements.intervalDaysInput.value);
  const hours = parseOptionalNumber(elements.intervalHoursInput.value);

  if (days === null || hours === null || days < 0 || hours < 0) {
    return null;
  }

  const intervalHours = days * 24 + hours;
  return intervalHours > 0 ? intervalHours : null;
}

function parseOptionalNumber(value) {
  const trimmed = value.trim();
  if (!trimmed) {
    return 0;
  }

  const parsed = Number(trimmed);
  return Number.isFinite(parsed) ? parsed : null;
}

function setIntervalInputs(intervalHours) {
  const normalizedHours =
    Number.isFinite(intervalHours) && intervalHours > 0 ? intervalHours : DEFAULT_INTERVAL_HOURS;
  const days = Math.floor(normalizedHours / 24);
  const hours = normalizedHours - days * 24;

  elements.intervalDaysInput.value = days ? String(days) : '';
  elements.intervalHoursInput.value = hours ? formatNumber(hours) : '';
}

function createId() {
  return ReminderModel.createId();
}

function formatDuration(ms) {
  const totalMinutes = Math.max(0, Math.floor(ms / 60_000));
  const days = Math.floor(totalMinutes / 1_440);
  const hours = Math.floor((totalMinutes % 1_440) / 60);
  const minutes = totalMinutes % 60;

  if (days > 0) {
    return `${days} 天 ${hours} 小时`;
  }

  if (hours > 0) {
    return `${hours} 小时 ${minutes} 分钟`;
  }

  return `${minutes} 分钟`;
}

function getCycleProgress(task, now) {
  const lastCompletedAt = new Date(task.lastCompletedAt).getTime();
  const intervalMs = task.intervalHours * 60 * 60 * 1000;

  if (!Number.isFinite(lastCompletedAt) || !Number.isFinite(intervalMs) || intervalMs <= 0) {
    return 0;
  }

  return Math.min(1, Math.max(0, (now - lastCompletedAt) / intervalMs));
}

function formatInterval(intervalHours) {
  const days = Math.floor(intervalHours / 24);
  const hours = intervalHours - days * 24;
  const parts = [];

  if (days > 0) {
    parts.push(`${days} 天`);
  }

  if (hours > 0) {
    parts.push(`${formatNumber(hours)} 小时`);
  }

  return parts.length ? parts.join(' ') : '0 小时';
}

function formatNumber(value) {
  return Number.isInteger(value) ? String(value) : String(Number(value.toFixed(2)));
}

function formatDateTime(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return '时间无效';
  }

  return new Intl.DateTimeFormat('zh-CN', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date);
}

function showStorageNotice(message) {
  elements.storageNotice.hidden = false;
  elements.storageNotice.textContent = message;
}
