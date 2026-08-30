(function exposeReminderModel(root, factory) {
  const model = factory();

  if (typeof module === 'object' && module.exports) {
    module.exports = model;
  } else {
    root.ReminderModel = model;
  }
})(typeof globalThis === 'object' ? globalThis : this, () => {
  const BACKUP_SCHEMA_VERSION = 3;
  const DEFAULT_INTERVAL_HOURS = 48;
  const DAY_MS = 24 * 60 * 60 * 1000;

  function createId(now = Date.now()) {
    return `${now}-${Math.random().toString(36).slice(2, 9)}`;
  }

  function toTimestamp(value) {
    if (value === null || value === undefined || value === '') {
      return null;
    }

    const timestamp = value instanceof Date ? value.getTime() : new Date(value).getTime();
    return Number.isFinite(timestamp) ? timestamp : null;
  }

  function toIsoString(value, fallback = new Date()) {
    const timestamp = toTimestamp(value);
    return new Date(timestamp === null ? fallback.getTime() : timestamp).toISOString();
  }

  function normalizeCompletion(value) {
    if (!value || typeof value !== 'object') {
      return null;
    }

    const completedAt = toTimestamp(value.completedAt);
    const scheduledDueAt = toTimestamp(value.scheduledDueAt);
    const intervalHours = Number(value.intervalHours);

    if (
      completedAt === null ||
      scheduledDueAt === null ||
      !Number.isFinite(intervalHours) ||
      intervalHours <= 0
    ) {
      return null;
    }

    return {
      id: typeof value.id === 'string' && value.id ? value.id : createId(completedAt),
      completedAt: new Date(completedAt).toISOString(),
      scheduledDueAt: new Date(scheduledDueAt).toISOString(),
      intervalHours,
    };
  }

  function normalizeCompletions(values) {
    if (!Array.isArray(values)) {
      return [];
    }

    const seenIds = new Set();
    return values
      .map(normalizeCompletion)
      .filter((completion) => {
        if (!completion || seenIds.has(completion.id)) {
          return false;
        }

        seenIds.add(completion.id);
        return true;
      })
      .sort((a, b) => toTimestamp(a.completedAt) - toTimestamp(b.completedAt));
  }

  function normalizeReminder(value, intervalHours) {
    if (!value || typeof value !== 'object') {
      return null;
    }

    const mode = value.mode;
    const amount = Number(value.amount ?? 0);
    if (!['due', 'remainingPercentage', 'remainingTime'].includes(mode) || !Number.isFinite(amount)) {
      return null;
    }
    if (mode === 'remainingPercentage' && (amount <= 0 || amount >= 100)) {
      return null;
    }
    if (mode === 'remainingTime' && (amount <= 0 || amount >= intervalHours)) {
      return null;
    }

    return {
      id: typeof value.id === 'string' && value.id ? value.id : createId(),
      mode,
      amount: mode === 'due' ? 0 : amount,
    };
  }

  function normalizeReminders(values, intervalHours) {
    if (!Array.isArray(values)) {
      return [];
    }

    const seenIds = new Set();
    return values
      .map((value) => normalizeReminder(value, intervalHours))
      .filter((reminder) => {
        if (!reminder || seenIds.has(reminder.id)) {
          return false;
        }

        seenIds.add(reminder.id);
        return true;
      });
  }

  function normalizeTask(value, fallbackDate = new Date()) {
    if (!value || typeof value !== 'object') {
      return null;
    }

    const name = typeof value.name === 'string' ? value.name.trim() : String(value.name || '').trim();
    const intervalHours = Number(value.intervalHours);
    if (!name || !Number.isFinite(intervalHours) || intervalHours <= 0) {
      return null;
    }

    const fallback = fallbackDate instanceof Date ? fallbackDate : new Date(fallbackDate);
    const safeFallback = Number.isFinite(fallback.getTime()) ? fallback : new Date();
    const lastCompletedAt = toIsoString(value.lastCompletedAt, safeFallback);
    const nextDueTimestamp = toTimestamp(value.nextDueAt);
    const nextDueAt = new Date(
      nextDueTimestamp === null
        ? new Date(lastCompletedAt).getTime() + intervalHours * 60 * 60 * 1000
        : nextDueTimestamp,
    ).toISOString();

    return {
      id: typeof value.id === 'string' && value.id ? value.id : createId(safeFallback.getTime()),
      name,
      intervalHours,
      lastCompletedAt,
      nextDueAt,
      createdAt: toIsoString(value.createdAt, safeFallback),
      completions: normalizeCompletions(value.completions),
      reminders: normalizeReminders(value.reminders, intervalHours),
    };
  }

  function normalizeTasks(values, fallbackDate = new Date()) {
    if (!Array.isArray(values)) {
      return [];
    }

    const seenIds = new Set();
    return values
      .map((value) => normalizeTask(value, fallbackDate))
      .filter((task) => {
        if (!task || seenIds.has(task.id)) {
          return false;
        }

        seenIds.add(task.id);
        return true;
      });
  }

  function createTask(value, createdAt = new Date()) {
    if (!value || typeof value !== 'object') {
      return null;
    }

    const name = typeof value.name === 'string' ? value.name.trim() : String(value.name || '').trim();
    const intervalHours = Number(value.intervalHours);
    const createdTimestamp = toTimestamp(createdAt);
    const customCompletedTimestamp = toTimestamp(value.lastCompletedAt);
    if (
      !name ||
      !Number.isFinite(intervalHours) ||
      intervalHours <= 0 ||
      createdTimestamp === null ||
      (value.lastCompletedAt !== null &&
        value.lastCompletedAt !== undefined &&
        value.lastCompletedAt !== '' &&
        (customCompletedTimestamp === null || customCompletedTimestamp > createdTimestamp))
    ) {
      return null;
    }

    const completedTimestamp = customCompletedTimestamp ?? createdTimestamp;
    return normalizeTask(
      {
        id: typeof value.id === 'string' && value.id ? value.id : createId(createdTimestamp),
        name,
        intervalHours,
        lastCompletedAt: new Date(completedTimestamp).toISOString(),
        nextDueAt: new Date(
          completedTimestamp + intervalHours * 60 * 60 * 1000,
        ).toISOString(),
        createdAt: new Date(createdTimestamp).toISOString(),
        completions: [],
        reminders: value.reminders,
      },
      new Date(createdTimestamp),
    );
  }

  function completeTask(task, completedAt = new Date()) {
    const normalized = normalizeTask(task, completedAt);
    if (!normalized) {
      return null;
    }

    const completedTimestamp = toTimestamp(completedAt);
    const safeCompletedAt = new Date(
      completedTimestamp === null ? Date.now() : completedTimestamp,
    ).toISOString();
    const completion = {
      id: createId(completedTimestamp === null ? Date.now() : completedTimestamp),
      completedAt: safeCompletedAt,
      scheduledDueAt: normalized.nextDueAt,
      intervalHours: normalized.intervalHours,
    };

    return {
      ...normalized,
      lastCompletedAt: safeCompletedAt,
      nextDueAt: new Date(
        new Date(safeCompletedAt).getTime() + normalized.intervalHours * 60 * 60 * 1000,
      ).toISOString(),
      completions: [...normalized.completions, completion],
    };
  }

  function backfillTask(task, completedAt, now = new Date()) {
    const normalized = normalizeTask(task, now);
    const completedTimestamp = toTimestamp(completedAt);
    const nowTimestamp = toTimestamp(now);
    const lastCompletedTimestamp = normalized ? toTimestamp(normalized.lastCompletedAt) : null;
    if (
      !normalized ||
      completedTimestamp === null ||
      nowTimestamp === null ||
      lastCompletedTimestamp === null ||
      completedTimestamp <= lastCompletedTimestamp ||
      completedTimestamp > nowTimestamp
    ) {
      return null;
    }

    return completeTask(normalized, new Date(completedTimestamp));
  }

  function createBackup(tasks, exportedAt = new Date()) {
    return {
      schemaVersion: BACKUP_SCHEMA_VERSION,
      exportedAt: toIsoString(exportedAt),
      tasks: normalizeTasks(tasks, exportedAt),
    };
  }

  function parseBackup(value, fallbackDate = new Date()) {
    let parsed;
    try {
      parsed = typeof value === 'string' ? JSON.parse(value) : value;
    } catch {
      throw new Error('请输入有效的 JSON。');
    }
    const rawTasks = Array.isArray(parsed) ? parsed : parsed?.tasks;

    if (!Array.isArray(rawTasks)) {
      throw new Error('备份必须是旧版任务数组或包含 tasks 数组的备份对象。');
    }

    const tasks = normalizeTasks(rawTasks, fallbackDate);
    return {
      schemaVersion: Array.isArray(parsed) ? 1 : Number(parsed.schemaVersion) || 2,
      tasks,
      completionCount: tasks.reduce((total, task) => total + task.completions.length, 0),
    };
  }

  function startOfLocalDay(value) {
    const date = value instanceof Date ? new Date(value) : new Date(value);
    date.setHours(0, 0, 0, 0);
    return date;
  }

  function localDateKey(value) {
    const date = value instanceof Date ? value : new Date(value);
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day}`;
  }

  function getTaskStatistics(task) {
    const completions = normalizeCompletions(task?.completions);
    const onTimeCount = completions.filter(
      (item) => toTimestamp(item.completedAt) <= toTimestamp(item.scheduledDueAt),
    ).length;

    return {
      total: completions.length,
      onTimeCount,
      onTimeRate: completions.length ? onTimeCount / completions.length : null,
      latestCompletedAt: completions.length ? completions[completions.length - 1].completedAt : null,
    };
  }

  function calculateStatistics(tasks, now = new Date()) {
    const safeTasks = normalizeTasks(tasks, now);
    const nowDate = now instanceof Date ? new Date(now) : new Date(now);
    const safeNow = Number.isFinite(nowDate.getTime()) ? nowDate : new Date();
    const todayStart = startOfLocalDay(safeNow);
    const sevenDayStart = new Date(todayStart);
    sevenDayStart.setDate(sevenDayStart.getDate() - 6);

    const completions = safeTasks
      .flatMap((task) => task.completions.map((completion) => ({ ...completion, taskId: task.id })))
      .filter((completion) => toTimestamp(completion.completedAt) <= safeNow.getTime());
    const todayKey = localDateKey(safeNow);
    const lastSeven = completions.filter(
      (completion) => toTimestamp(completion.completedAt) >= sevenDayStart.getTime(),
    );
    const onTimeCount = completions.filter(
      (completion) => toTimestamp(completion.completedAt) <= toTimestamp(completion.scheduledDueAt),
    ).length;
    const dailyCounts = new Map();
    lastSeven.forEach((completion) => {
      const key = localDateKey(completion.completedAt);
      dailyCounts.set(key, (dailyCounts.get(key) || 0) + 1);
    });

    const daily = Array.from({ length: 7 }, (_, index) => {
      const date = new Date(sevenDayStart);
      date.setDate(date.getDate() + index);
      const key = localDateKey(date);
      return {
        key,
        label: `${date.getMonth() + 1}/${date.getDate()}`,
        count: dailyCounts.get(key) || 0,
      };
    });

    const taskRanking = safeTasks
      .map((task) => ({
        taskId: task.id,
        name: task.name,
        ...getTaskStatistics(task),
      }))
      .filter((item) => item.total > 0)
      .sort((a, b) => b.total - a.total || a.name.localeCompare(b.name, 'zh-CN'));

    return {
      total: completions.length,
      today: completions.filter((completion) => localDateKey(completion.completedAt) === todayKey).length,
      lastSevenDays: lastSeven.length,
      onTimeCount,
      onTimeRate: completions.length ? onTimeCount / completions.length : null,
      daily,
      taskRanking,
    };
  }

  return {
    BACKUP_SCHEMA_VERSION,
    DEFAULT_INTERVAL_HOURS,
    DAY_MS,
    backfillTask,
    calculateStatistics,
    completeTask,
    createBackup,
    createId,
    createTask,
    getTaskStatistics,
    localDateKey,
    normalizeCompletion,
    normalizeReminder,
    normalizeReminders,
    normalizeTask,
    normalizeTasks,
    parseBackup,
    toTimestamp,
  };
});
