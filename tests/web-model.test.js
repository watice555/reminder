const assert = require('node:assert/strict');
const test = require('node:test');

const model = require('../pwa/model.js');

function legacyTask(overrides = {}) {
  return {
    id: 'task-1',
    name: '换滤芯',
    intervalHours: 48,
    lastCompletedAt: '2026-07-20T04:00:00.000Z',
    nextDueAt: '2026-07-22T04:00:00.000Z',
    createdAt: '2026-07-20T04:00:00.000Z',
    ...overrides,
  };
}

function completion(id, completedAt, scheduledDueAt = completedAt) {
  return {
    id,
    completedAt,
    scheduledDueAt,
    intervalHours: 48,
  };
}

test('旧任务迁移为空完成记录，不把周期起点伪造成完成', () => {
  const task = model.normalizeTask(legacyTask());

  assert.ok(task);
  assert.deepEqual(task.completions, []);
  assert.equal(model.calculateStatistics([task], new Date('2026-07-22T05:00:00.000Z')).total, 0);
});

test('完成任务会记录旧到期时间和周期快照，再从完成时刻重置', () => {
  const completedAt = new Date('2026-07-22T03:30:00.000Z');
  const result = model.completeTask(legacyTask(), completedAt);

  assert.ok(result);
  assert.equal(result.completions.length, 1);
  assert.equal(result.completions[0].completedAt, completedAt.toISOString());
  assert.equal(result.completions[0].scheduledDueAt, '2026-07-22T04:00:00.000Z');
  assert.equal(result.completions[0].intervalHours, 48);
  assert.equal(result.lastCompletedAt, completedAt.toISOString());
  assert.equal(result.nextDueAt, '2026-07-24T03:30:00.000Z');
});

test('创建任务可使用过去的完成时间作为周期锚点，但不计入完成统计', () => {
  const createdAt = new Date('2026-08-30T10:00:00.000Z');
  const lastCompletedAt = new Date('2026-08-10T10:00:00.000Z');
  const task = model.createTask(
    {
      name: '30 天循环',
      intervalHours: 30 * 24,
      lastCompletedAt,
    },
    createdAt,
  );

  assert.ok(task);
  assert.equal(task.createdAt, createdAt.toISOString());
  assert.equal(task.lastCompletedAt, lastCompletedAt.toISOString());
  assert.equal(task.nextDueAt, '2026-09-09T10:00:00.000Z');
  assert.deepEqual(task.completions, []);
  assert.equal(model.calculateStatistics([task], createdAt).total, 0);
});

test('默认创建仍以创建时刻作为当前周期起点', () => {
  const createdAt = new Date('2026-08-30T10:00:00.000Z');
  const task = model.createTask({ name: '默认任务', intervalHours: 48 }, createdAt);

  assert.ok(task);
  assert.equal(task.lastCompletedAt, createdAt.toISOString());
  assert.equal(task.nextDueAt, '2026-09-01T10:00:00.000Z');
  assert.deepEqual(task.completions, []);
});

test('补记完成会按指定时间重置，并保留补记前的计划到期时间', () => {
  const now = new Date('2026-07-22T10:00:00.000Z');
  const completedAt = new Date('2026-07-22T07:00:00.000Z');
  const result = model.backfillTask(legacyTask(), completedAt, now);

  assert.ok(result);
  assert.equal(result.completions.length, 1);
  assert.equal(result.completions[0].completedAt, completedAt.toISOString());
  assert.equal(result.completions[0].scheduledDueAt, '2026-07-22T04:00:00.000Z');
  assert.equal(result.nextDueAt, '2026-07-24T07:00:00.000Z');
});

test('补记完成拒绝不晚于上次完成或晚于当前时间的值', () => {
  const now = new Date('2026-07-22T10:00:00.000Z');
  const original = legacyTask();

  assert.equal(model.backfillTask(original, '2026-07-20T04:00:00.000Z', now), null);
  assert.equal(model.backfillTask(original, '2026-07-20T03:59:00.000Z', now), null);
  assert.equal(model.backfillTask(original, '2026-07-22T10:01:00.000Z', now), null);
  assert.deepEqual(original, legacyTask());
});

test('自定义周期锚点和补记记录可通过 v3 备份往返', () => {
  const createdAt = new Date('2026-08-30T10:00:00.000Z');
  const task = model.createTask(
    {
      name: '换滤芯',
      intervalHours: 30 * 24,
      lastCompletedAt: '2026-08-10T10:00:00.000Z',
      reminders: [{ id: 'due', mode: 'due', amount: 0 }],
    },
    createdAt,
  );
  const completed = model.backfillTask(task, '2026-08-20T10:00:00.000Z', createdAt);
  const restored = model.parseBackup(JSON.stringify(model.createBackup([completed], createdAt)));

  assert.equal(restored.tasks.length, 1);
  assert.deepEqual(restored.tasks[0], completed);
  assert.equal(restored.completionCount, 1);
});

test('迁移会过滤损坏及重复完成记录', () => {
  const valid = completion(
    'completion-1',
    '2026-07-21T04:00:00.000Z',
    '2026-07-21T05:00:00.000Z',
  );
  const task = model.normalizeTask(
    legacyTask({
      completions: [
        valid,
        { ...valid, completedAt: '2026-07-22T04:00:00.000Z' },
        { id: 'broken', completedAt: 'not-a-date', scheduledDueAt: 'also-bad', intervalHours: 48 },
      ],
    }),
  );

  assert.equal(task.completions.length, 1);
  assert.equal(task.completions[0].id, 'completion-1');
});

test('备份导入兼容旧数组与 v3 包装，v3 往返保留历史和 iOS 提醒配置', () => {
  const tasks = [
    legacyTask({
      completions: [
        completion(
          'completion-1',
          '2026-07-21T04:00:00.000Z',
          '2026-07-21T05:00:00.000Z',
        ),
      ],
      reminders: [
        { id: 'due-rule', mode: 'due', amount: 0 },
        { id: 'percent-rule', mode: 'remainingPercentage', amount: 25 },
      ],
    }),
  ];

  const legacy = model.parseBackup(JSON.stringify(tasks));
  assert.equal(legacy.schemaVersion, 1);
  assert.equal(legacy.completionCount, 1);

  const exportedAt = new Date('2026-07-22T05:00:00.000Z');
  const envelope = model.createBackup(tasks, exportedAt);
  const v3 = model.parseBackup(JSON.stringify(envelope));
  assert.equal(envelope.schemaVersion, 3);
  assert.equal(envelope.exportedAt, exportedAt.toISOString());
  assert.deepEqual(v3.tasks, legacy.tasks);
});

test('Web 往返会过滤无效提醒并保留有效的 iOS 提醒配置', () => {
  const task = model.normalizeTask(
    legacyTask({
      reminders: [
        { id: 'due', mode: 'due' },
        { id: 'percentage', mode: 'remainingPercentage', amount: 20 },
        { id: 'bad-percentage', mode: 'remainingPercentage', amount: 100 },
        { id: 'bad-time', mode: 'remainingTime', amount: 48 },
        { id: 'bad-mode', mode: 'unknown', amount: 1 },
      ],
    }),
  );

  assert.deepEqual(task.reminders, [
    { id: 'due', mode: 'due', amount: 0 },
    { id: 'percentage', mode: 'remainingPercentage', amount: 20 },
  ]);
});

test('统计使用本地自然日，计算今日、近七天、累计和准时率', () => {
  const now = new Date(2026, 6, 22, 12, 0, 0);
  const today = new Date(2026, 6, 22, 9, 0, 0).toISOString();
  const sixDaysAgo = new Date(2026, 6, 16, 8, 0, 0).toISOString();
  const sevenDaysAgo = new Date(2026, 6, 15, 8, 0, 0).toISOString();
  const task = legacyTask({
    completions: [
      completion('today', today, new Date(2026, 6, 22, 10, 0, 0).toISOString()),
      completion('six-days', sixDaysAgo, new Date(2026, 6, 16, 7, 0, 0).toISOString()),
      completion('seven-days', sevenDaysAgo, new Date(2026, 6, 15, 9, 0, 0).toISOString()),
    ],
  });

  const statistics = model.calculateStatistics([task], now);
  assert.equal(statistics.today, 1);
  assert.equal(statistics.lastSevenDays, 2);
  assert.equal(statistics.total, 3);
  assert.equal(statistics.onTimeCount, 2);
  assert.equal(statistics.onTimeRate, 2 / 3);
  assert.equal(statistics.daily.reduce((sum, day) => sum + day.count, 0), 2);
  assert.equal(statistics.taskRanking[0].total, 3);
});

test('重复任务 id 只保留第一条，避免 IndexedDB 与内存统计分歧', () => {
  const tasks = model.normalizeTasks([
    legacyTask(),
    legacyTask({ name: '重复任务' }),
  ]);

  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].name, '换滤芯');
});
