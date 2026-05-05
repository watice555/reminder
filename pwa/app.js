const DB_NAME = 'cycle-reminder-db';
const DB_VERSION = 1;
const TASK_STORE = 'tasks';
const SNAPSHOT_KEY = 'cycle-reminder.snapshot.v1';
const DEFAULT_INTERVAL_HOURS = 48;

/** @type {Array<ReminderTask>} */
let tasks = [];
let db = null;
let editingTaskId = null;
let deferredInstallPrompt = null;

/**
 * @typedef {Object} ReminderTask
 * @property {string} id
 * @property {string} name
 * @property {number} intervalHours
 * @property {string} lastCompletedAt
 * @property {string} nextDueAt
 * @property {string} createdAt
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
  intervalInput: document.querySelector('#intervalInput'),
  cancelTaskButton: document.querySelector('#cancelTaskButton'),
  dataDialog: document.querySelector('#dataDialog'),
  dataDialogTitle: document.querySelector('#dataDialogTitle'),
  dataText: document.querySelector('#dataText'),
  closeDataButton: document.querySelector('#closeDataButton'),
  confirmImportButton: document.querySelector('#confirmImportButton'),
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

  navigator.serviceWorker.register('./sw.js').catch(() => {
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
        writeSnapshot(storedTasks);
        return storedTasks.filter(isValidTask);
      }
    } catch {
      showStorageNotice('IndexedDB 读取失败，正在尝试从本地快照恢复。');
    }
  }

  return readSnapshot().filter(isValidTask);
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
  const intervalHours = Number(elements.intervalInput.value);

  if (!name) {
    alert('请输入任务名称。');
    return;
  }

  if (!Number.isFinite(intervalHours) || intervalHours <= 0) {
    alert('请输入大于 0 的小时数，例如 48。');
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
      },
      ...tasks,
    ];
  }

  await persistTasks(tasks);
  closeTaskDialog();
  render();
}

async function completeTask(taskId) {
  const completedAt = new Date();
  tasks = tasks.map((task) =>
    task.id === taskId
      ? {
          ...task,
          lastCompletedAt: completedAt.toISOString(),
          nextDueAt: addHours(completedAt, task.intervalHours).toISOString(),
        }
      : task,
  );

  await persistTasks(tasks);
  render();
}

async function deleteTask(taskId) {
  const task = tasks.find((item) => item.id === taskId);
  if (!confirm(`确定删除“${task?.name || '这个任务'}”吗？`)) {
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
  elements.intervalInput.value = task ? String(task.intervalHours) : String(DEFAULT_INTERVAL_HOURS);
  elements.taskDialog.showModal();
  setTimeout(() => elements.taskNameInput.focus(), 50);
}

function closeTaskDialog() {
  editingTaskId = null;
  elements.taskForm.reset();
  elements.intervalInput.value = String(DEFAULT_INTERVAL_HOURS);
  elements.taskDialog.close();
}

function openExportDialog() {
  elements.dataDialogTitle.textContent = '导出 JSON';
  elements.dataText.value = JSON.stringify(tasks, null, 2);
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
    const parsed = JSON.parse(elements.dataText.value);
    if (!Array.isArray(parsed)) {
      alert('JSON 顶层必须是任务数组。');
      return;
    }

    const importedTasks = parsed.map(normalizeImportedTask).filter(Boolean);
    if (!confirm(`将用 ${importedTasks.length} 个导入任务替换当前任务，确定继续吗？`)) {
      return;
    }

    tasks = importedTasks;
    await persistTasks(tasks);
    closeDataDialog();
    render();
  } catch {
    alert('请输入有效的 JSON。');
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
  const sortedTasks = [...tasks].sort(
    (a, b) => new Date(a.nextDueAt).getTime() - new Date(b.nextDueAt).getTime(),
  );

  elements.summary.textContent = `${tasks.length} 个任务保存在本机`;
  elements.taskList.textContent = '';

  if (!sortedTasks.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-state';
    empty.innerHTML = '<strong>还没有任务</strong><span>新增一个任务，例如“换滤芯”，设置 48 小时循环。</span>';
    elements.taskList.append(empty);
    return;
  }

  sortedTasks.forEach((task) => {
    const card = elements.taskTemplate.content.firstElementChild.cloneNode(true);
    const remainingMs = new Date(task.nextDueAt).getTime() - now;
    const isOverdue = remainingMs <= 0;

    card.classList.toggle('is-overdue', isOverdue);
    card.querySelector('.task-name').textContent = task.name;
    card.querySelector('.task-cycle').textContent = `${task.intervalHours} 小时循环`;
    card.querySelector('.task-status').textContent = isOverdue ? '已到期' : '进行中';
    card.querySelector('.task-status').classList.toggle('is-active', !isOverdue);
    card.querySelector('.task-status').classList.toggle('is-overdue', isOverdue);
    card.querySelector('.task-remaining').textContent = isOverdue
      ? `超时 ${formatDuration(Math.abs(remainingMs))}`
      : `剩余 ${formatDuration(remainingMs)}`;
    card.querySelector('.task-due').textContent = `下次到期：${formatDateTime(task.nextDueAt)}`;
    card.querySelector('.task-completed').textContent = `上次完成：${formatDateTime(task.lastCompletedAt)}`;
    card.querySelector('.done-button').addEventListener('click', () => completeTask(task.id));
    card.querySelector('.edit-button').addEventListener('click', () => openTaskDialog(task));
    card.querySelector('.delete-button').addEventListener('click', () => deleteTask(task.id));

    elements.taskList.append(card);
  });
}

function addHours(date, hours) {
  return new Date(date.getTime() + hours * 60 * 60 * 1000);
}

function createId() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
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

function isValidTask(value) {
  return (
    value &&
    typeof value === 'object' &&
    typeof value.id === 'string' &&
    typeof value.name === 'string' &&
    typeof value.intervalHours === 'number' &&
    typeof value.lastCompletedAt === 'string' &&
    typeof value.nextDueAt === 'string'
  );
}

function normalizeImportedTask(value) {
  if (!value || typeof value !== 'object') {
    return null;
  }

  const intervalHours = Number(value.intervalHours);
  const lastCompletedAt = value.lastCompletedAt || new Date().toISOString();
  const nextDueAt =
    value.nextDueAt || addHours(new Date(lastCompletedAt), intervalHours || DEFAULT_INTERVAL_HOURS).toISOString();

  if (!value.name || !Number.isFinite(intervalHours) || intervalHours <= 0) {
    return null;
  }

  return {
    id: value.id || createId(),
    name: String(value.name),
    intervalHours,
    lastCompletedAt,
    nextDueAt,
    createdAt: value.createdAt || new Date().toISOString(),
  };
}

function showStorageNotice(message) {
  elements.storageNotice.hidden = false;
  elements.storageNotice.textContent = message;
}
