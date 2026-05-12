import AsyncStorage from '@react-native-async-storage/async-storage';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  FlatList,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

type ReminderTask = {
  id: string;
  name: string;
  intervalHours: number;
  lastCompletedAt: string;
  nextDueAt: string;
  createdAt: string;
};

type TaskFormState = {
  name: string;
  intervalDays: string;
  intervalHours: string;
};

const STORAGE_KEY = 'reminder.tasks.v1';
const DEFAULT_INTERVAL_HOURS = 48;

const initialForm: TaskFormState = {
  name: '',
  ...splitIntervalHours(DEFAULT_INTERVAL_HOURS),
};

export default function App() {
  const [tasks, setTasks] = useState<ReminderTask[]>([]);
  const [now, setNow] = useState(() => Date.now());
  const [isLoading, setIsLoading] = useState(true);
  const [form, setForm] = useState<TaskFormState>(initialForm);
  const [editingTask, setEditingTask] = useState<ReminderTask | null>(null);
  const [isFormOpen, setIsFormOpen] = useState(false);
  const [importText, setImportText] = useState('');
  const [isImportOpen, setIsImportOpen] = useState(false);
  const [exportText, setExportText] = useState('');
  const [isExportOpen, setIsExportOpen] = useState(false);

  useEffect(() => {
    loadTasks();
  }, []);

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    if (!isLoading) {
      saveTasks(tasks);
    }
  }, [tasks, isLoading]);

  const sortedTasks = useMemo(
    () =>
      [...tasks].sort(
        (a, b) => new Date(a.nextDueAt).getTime() - new Date(b.nextDueAt).getTime(),
      ),
    [tasks],
  );

  async function loadTasks() {
    try {
      const raw = await AsyncStorage.getItem(STORAGE_KEY);
      if (!raw) {
        return;
      }

      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        setTasks(parsed.filter(isValidTask));
      }
    } catch {
      Alert.alert('读取失败', '本地任务数据无法读取。你可以继续使用，新的保存会覆盖损坏数据。');
    } finally {
      setIsLoading(false);
    }
  }

  async function saveTasks(nextTasks: ReminderTask[]) {
    try {
      await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(nextTasks));
    } catch {
      Alert.alert('保存失败', '任务没有成功写入本地存储，请稍后再试。');
    }
  }

  function openCreateForm() {
    setEditingTask(null);
    setForm(initialForm);
    setIsFormOpen(true);
  }

  function openEditForm(task: ReminderTask) {
    setEditingTask(task);
    setForm({
      name: task.name,
      ...splitIntervalHours(task.intervalHours),
    });
    setIsFormOpen(true);
  }

  function closeForm() {
    setIsFormOpen(false);
    setEditingTask(null);
    setForm(initialForm);
  }

  function submitTask() {
    const name = form.name.trim();
    const intervalHours = parseFormInterval(form);

    if (!name) {
      Alert.alert('缺少名称', '请输入任务名称。');
      return;
    }

    if (intervalHours === null) {
      Alert.alert('循环时间无效', '请输入大于 0 的循环时间。天和小时都可以不填，不填按 0 计算。');
      return;
    }

    if (editingTask) {
      setTasks((current) =>
        current.map((task) => {
          if (task.id !== editingTask.id) {
            return task;
          }

          const lastCompletedAt = task.lastCompletedAt || new Date().toISOString();
          return {
            ...task,
            name,
            intervalHours,
            nextDueAt: addHours(new Date(lastCompletedAt), intervalHours).toISOString(),
          };
        }),
      );
    } else {
      const completedAt = new Date();
      const newTask: ReminderTask = {
        id: createId(),
        name,
        intervalHours,
        lastCompletedAt: completedAt.toISOString(),
        nextDueAt: addHours(completedAt, intervalHours).toISOString(),
        createdAt: completedAt.toISOString(),
      };

      setTasks((current) => [newTask, ...current]);
    }

    closeForm();
  }

  function completeTask(taskId: string) {
    const completedAt = new Date();

    setTasks((current) =>
      current.map((task) =>
        task.id === taskId
          ? {
              ...task,
              lastCompletedAt: completedAt.toISOString(),
              nextDueAt: addHours(completedAt, task.intervalHours).toISOString(),
            }
          : task,
      ),
    );
  }

  function deleteTask(taskId: string) {
    const task = tasks.find((item) => item.id === taskId);
    Alert.alert('删除任务', `确定删除“${task?.name ?? '这个任务'}”吗？`, [
      { text: '取消', style: 'cancel' },
      {
        text: '删除',
        style: 'destructive',
        onPress: () => setTasks((current) => current.filter((item) => item.id !== taskId)),
      },
    ]);
  }

  function exportTasks() {
    const payload = JSON.stringify(tasks, null, 2);
    setExportText(payload || '[]');
    setIsExportOpen(true);
  }

  function importTasks() {
    try {
      const parsed = JSON.parse(importText);
      if (!Array.isArray(parsed)) {
        Alert.alert('导入失败', 'JSON 顶层必须是任务数组。');
        return;
      }

      const normalized = parsed.map(normalizeImportedTask).filter(Boolean) as ReminderTask[];
      setTasks(normalized);
      setImportText('');
      setIsImportOpen(false);
    } catch {
      Alert.alert('导入失败', '请输入有效的 JSON。');
    }
  }

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar style="dark" />
      <View style={styles.screen}>
        <View style={styles.header}>
          <View>
            <Text style={styles.title}>循环提醒</Text>
            <Text style={styles.subtitle}>{tasks.length} 个任务保存在本机</Text>
          </View>
          <Pressable style={styles.primaryButton} onPress={openCreateForm}>
            <Text style={styles.primaryButtonText}>新增</Text>
          </Pressable>
        </View>

        <View style={styles.toolbar}>
          <Pressable style={styles.secondaryButton} onPress={exportTasks}>
            <Text style={styles.secondaryButtonText}>导出 JSON</Text>
          </Pressable>
          <Pressable style={styles.secondaryButton} onPress={() => setIsImportOpen(true)}>
            <Text style={styles.secondaryButtonText}>导入 JSON</Text>
          </Pressable>
        </View>

        {isLoading ? (
          <View style={styles.emptyState}>
            <Text style={styles.emptyTitle}>正在读取任务</Text>
          </View>
        ) : (
          <FlatList
            data={sortedTasks}
            keyExtractor={(item) => item.id}
            contentContainerStyle={sortedTasks.length ? styles.listContent : styles.emptyList}
            renderItem={({ item }) => (
              <TaskCard
                task={item}
                now={now}
                onComplete={() => completeTask(item.id)}
                onEdit={() => openEditForm(item)}
                onDelete={() => deleteTask(item.id)}
              />
            )}
            ListEmptyComponent={
              <View style={styles.emptyState}>
                <Text style={styles.emptyTitle}>还没有任务</Text>
                <Text style={styles.emptyText}>新增一个任务，例如“换滤芯”，设置 2 天循环。</Text>
              </View>
            }
          />
        )}
      </View>

      <TaskFormModal
        form={form}
        isOpen={isFormOpen}
        isEditing={Boolean(editingTask)}
        onChange={setForm}
        onClose={closeForm}
        onSubmit={submitTask}
      />

      <ImportModal
        isOpen={isImportOpen}
        value={importText}
        onChange={setImportText}
        onClose={() => setIsImportOpen(false)}
        onSubmit={importTasks}
      />

      <ExportModal
        isOpen={isExportOpen}
        value={exportText}
        onClose={() => setIsExportOpen(false)}
      />
    </SafeAreaView>
  );
}

function TaskCard({
  task,
  now,
  onComplete,
  onEdit,
  onDelete,
}: {
  task: ReminderTask;
  now: number;
  onComplete: () => void;
  onEdit: () => void;
  onDelete: () => void;
}) {
  const nextDueAt = new Date(task.nextDueAt).getTime();
  const remainingMs = nextDueAt - now;
  const isOverdue = remainingMs <= 0;
  const progress = getCycleProgress(task, now);
  const progressPercent = Math.round(progress * 100);

  return (
    <View style={[styles.card, isOverdue && styles.overdueCard]}>
      <View style={styles.cardTopRow}>
        <View style={styles.cardTitleWrap}>
          <Text style={styles.taskName}>{task.name}</Text>
          <Text style={styles.taskMeta}>{formatInterval(task.intervalHours)}循环</Text>
        </View>
        <Text style={[styles.statusPill, isOverdue ? styles.statusOverdue : styles.statusActive]}>
          {isOverdue ? '已到期' : '进行中'}
        </Text>
      </View>

      <View style={styles.timeBlock}>
        <Text style={[styles.remainingText, isOverdue && styles.overdueText]}>
          {isOverdue ? `超时 ${formatDuration(Math.abs(remainingMs))}` : `剩余 ${formatDuration(remainingMs)}`}
        </Text>
        <Text style={styles.dueText}>下次到期：{formatDateTime(task.nextDueAt)}</Text>
        <Text style={styles.dueText}>上次完成：{formatDateTime(task.lastCompletedAt)}</Text>
      </View>

      <View
        style={styles.progressBlock}
        accessibilityLabel={`当前循环已过去 ${progressPercent}%`}
      >
        <View style={styles.progressMetaRow}>
          <Text style={styles.progressLabel}>本轮进度</Text>
          <Text style={[styles.progressValue, isOverdue && styles.progressValueOverdue]}>
            已过去 {progressPercent}%
          </Text>
        </View>
        <View style={styles.progressTrack}>
          <View
            style={[
              styles.progressFill,
              isOverdue && styles.progressFillOverdue,
              { width: `${progressPercent}%` },
            ]}
          />
        </View>
      </View>

      <View style={styles.cardActions}>
        <Pressable style={styles.doneButton} onPress={onComplete}>
          <Text style={styles.doneButtonText}>完成并重置</Text>
        </Pressable>
        <Pressable style={styles.smallButton} onPress={onEdit}>
          <Text style={styles.smallButtonText}>编辑</Text>
        </Pressable>
        <Pressable style={styles.deleteButton} onPress={onDelete}>
          <Text style={styles.deleteButtonText}>删除</Text>
        </Pressable>
      </View>
    </View>
  );
}

function TaskFormModal({
  form,
  isOpen,
  isEditing,
  onChange,
  onClose,
  onSubmit,
}: {
  form: TaskFormState;
  isOpen: boolean;
  isEditing: boolean;
  onChange: (form: TaskFormState) => void;
  onClose: () => void;
  onSubmit: () => void;
}) {
  return (
    <Modal animationType="slide" transparent visible={isOpen} onRequestClose={onClose}>
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        style={styles.modalOverlay}
      >
        <View style={styles.modalPanel}>
          <Text style={styles.modalTitle}>{isEditing ? '编辑任务' : '新增任务'}</Text>

          <Text style={styles.label}>任务名称</Text>
          <TextInput
            value={form.name}
            onChangeText={(name) => onChange({ ...form, name })}
            placeholder="例如：换滤芯"
            style={styles.input}
            returnKeyType="next"
          />

          <Text style={styles.label}>循环时间</Text>
          <View style={styles.intervalRow}>
            <View style={styles.intervalField}>
              <TextInput
                value={form.intervalDays}
                onChangeText={(intervalDays) => onChange({ ...form, intervalDays })}
                placeholder="0"
                keyboardType="number-pad"
                style={styles.input}
              />
              <Text style={styles.intervalUnit}>天</Text>
            </View>
            <View style={styles.intervalField}>
              <TextInput
                value={form.intervalHours}
                onChangeText={(intervalHours) => onChange({ ...form, intervalHours })}
                placeholder="0"
                keyboardType="decimal-pad"
                style={styles.input}
              />
              <Text style={styles.intervalUnit}>小时</Text>
            </View>
          </View>

          <View style={styles.modalActions}>
            <Pressable style={styles.secondaryButton} onPress={onClose}>
              <Text style={styles.secondaryButtonText}>取消</Text>
            </Pressable>
            <Pressable style={styles.primaryButton} onPress={onSubmit}>
              <Text style={styles.primaryButtonText}>{isEditing ? '保存' : '创建'}</Text>
            </Pressable>
          </View>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

function ImportModal({
  isOpen,
  value,
  onChange,
  onClose,
  onSubmit,
}: {
  isOpen: boolean;
  value: string;
  onChange: (text: string) => void;
  onClose: () => void;
  onSubmit: () => void;
}) {
  return (
    <Modal animationType="slide" transparent visible={isOpen} onRequestClose={onClose}>
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        style={styles.modalOverlay}
      >
        <View style={styles.importPanel}>
          <Text style={styles.modalTitle}>导入 JSON</Text>
          <TextInput
            value={value}
            onChangeText={onChange}
            placeholder="粘贴之前导出的任务 JSON"
            style={styles.textArea}
            multiline
            textAlignVertical="top"
            autoCapitalize="none"
            autoCorrect={false}
          />
          <View style={styles.modalActions}>
            <Pressable style={styles.secondaryButton} onPress={onClose}>
              <Text style={styles.secondaryButtonText}>取消</Text>
            </Pressable>
            <Pressable style={styles.primaryButton} onPress={onSubmit}>
              <Text style={styles.primaryButtonText}>导入</Text>
            </Pressable>
          </View>
        </View>
      </KeyboardAvoidingView>
    </Modal>
  );
}

function ExportModal({
  isOpen,
  value,
  onClose,
}: {
  isOpen: boolean;
  value: string;
  onClose: () => void;
}) {
  return (
    <Modal animationType="slide" transparent visible={isOpen} onRequestClose={onClose}>
      <View style={styles.modalOverlay}>
        <View style={styles.importPanel}>
          <Text style={styles.modalTitle}>导出 JSON</Text>
          <ScrollView style={styles.exportBox}>
            <Text selectable style={styles.exportText}>
              {value}
            </Text>
          </ScrollView>
          <View style={styles.modalActions}>
            <Pressable style={styles.primaryButton} onPress={onClose}>
              <Text style={styles.primaryButtonText}>完成</Text>
            </Pressable>
          </View>
        </View>
      </View>
    </Modal>
  );
}

function addHours(date: Date, hours: number) {
  return new Date(date.getTime() + hours * 60 * 60 * 1000);
}

function parseFormInterval(form: TaskFormState) {
  const days = parseOptionalNumber(form.intervalDays);
  const hours = parseOptionalNumber(form.intervalHours);

  if (days === null || hours === null || days < 0 || hours < 0) {
    return null;
  }

  const intervalHours = days * 24 + hours;
  return intervalHours > 0 ? intervalHours : null;
}

function parseOptionalNumber(value: string) {
  const trimmed = value.trim();
  if (!trimmed) {
    return 0;
  }

  const parsed = Number(trimmed);
  return Number.isFinite(parsed) ? parsed : null;
}

function splitIntervalHours(intervalHours: number): Pick<TaskFormState, 'intervalDays' | 'intervalHours'> {
  const normalizedHours =
    Number.isFinite(intervalHours) && intervalHours > 0 ? intervalHours : DEFAULT_INTERVAL_HOURS;
  const days = Math.floor(normalizedHours / 24);
  const hours = normalizedHours - days * 24;

  return {
    intervalDays: days ? String(days) : '',
    intervalHours: hours ? formatNumber(hours) : '',
  };
}

function createId() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
}

function formatDuration(ms: number) {
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

function getCycleProgress(task: ReminderTask, now: number) {
  const lastCompletedAt = new Date(task.lastCompletedAt).getTime();
  const intervalMs = task.intervalHours * 60 * 60 * 1000;

  if (!Number.isFinite(lastCompletedAt) || !Number.isFinite(intervalMs) || intervalMs <= 0) {
    return 0;
  }

  return Math.min(1, Math.max(0, (now - lastCompletedAt) / intervalMs));
}

function formatInterval(intervalHours: number) {
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

function formatNumber(value: number) {
  return Number.isInteger(value) ? String(value) : String(Number(value.toFixed(2)));
}

function formatDateTime(value: string) {
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

function isValidTask(value: unknown): value is ReminderTask {
  if (!value || typeof value !== 'object') {
    return false;
  }

  const task = value as ReminderTask;
  return (
    typeof task.id === 'string' &&
    typeof task.name === 'string' &&
    typeof task.intervalHours === 'number' &&
    typeof task.lastCompletedAt === 'string' &&
    typeof task.nextDueAt === 'string'
  );
}

function normalizeImportedTask(value: unknown) {
  if (!value || typeof value !== 'object') {
    return null;
  }

  const item = value as Partial<ReminderTask>;
  const intervalHours = Number(item.intervalHours);
  const lastCompletedAt = item.lastCompletedAt || new Date().toISOString();
  const nextDueAt =
    item.nextDueAt || addHours(new Date(lastCompletedAt), intervalHours || DEFAULT_INTERVAL_HOURS).toISOString();

  if (!item.name || !Number.isFinite(intervalHours) || intervalHours <= 0) {
    return null;
  }

  return {
    id: item.id || createId(),
    name: item.name,
    intervalHours,
    lastCompletedAt,
    nextDueAt,
    createdAt: item.createdAt || new Date().toISOString(),
  };
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#f6f4ef',
  },
  screen: {
    flex: 1,
    paddingHorizontal: 18,
    paddingTop: 18,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 14,
  },
  title: {
    color: '#1f2933',
    fontSize: 28,
    fontWeight: '700',
  },
  subtitle: {
    color: '#6b7280',
    fontSize: 14,
    marginTop: 4,
  },
  toolbar: {
    flexDirection: 'row',
    gap: 10,
    marginTop: 18,
    marginBottom: 6,
  },
  listContent: {
    paddingVertical: 12,
    gap: 12,
  },
  emptyList: {
    flexGrow: 1,
    justifyContent: 'center',
  },
  emptyState: {
    alignItems: 'center',
    paddingHorizontal: 24,
  },
  emptyTitle: {
    color: '#1f2933',
    fontSize: 19,
    fontWeight: '700',
  },
  emptyText: {
    color: '#6b7280',
    fontSize: 15,
    lineHeight: 22,
    marginTop: 8,
    textAlign: 'center',
  },
  card: {
    backgroundColor: '#ffffff',
    borderColor: '#e5e0d8',
    borderRadius: 8,
    borderWidth: 1,
    padding: 16,
  },
  overdueCard: {
    borderColor: '#e37a61',
  },
  cardTopRow: {
    alignItems: 'flex-start',
    flexDirection: 'row',
    justifyContent: 'space-between',
    gap: 12,
  },
  cardTitleWrap: {
    flex: 1,
  },
  taskName: {
    color: '#111827',
    fontSize: 19,
    fontWeight: '700',
  },
  taskMeta: {
    color: '#6b7280',
    fontSize: 13,
    marginTop: 4,
  },
  statusPill: {
    borderRadius: 999,
    fontSize: 12,
    fontWeight: '700',
    overflow: 'hidden',
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  statusActive: {
    backgroundColor: '#dff2e6',
    color: '#17613a',
  },
  statusOverdue: {
    backgroundColor: '#ffe3dd',
    color: '#b23923',
  },
  timeBlock: {
    marginTop: 18,
  },
  remainingText: {
    color: '#17613a',
    fontSize: 26,
    fontWeight: '800',
  },
  overdueText: {
    color: '#b23923',
  },
  dueText: {
    color: '#6b7280',
    fontSize: 13,
    marginTop: 6,
  },
  progressBlock: {
    marginTop: 16,
  },
  progressMetaRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
    gap: 10,
  },
  progressLabel: {
    color: '#374151',
    fontSize: 13,
    fontWeight: '700',
  },
  progressValue: {
    color: '#17613a',
    fontSize: 13,
    fontWeight: '800',
  },
  progressValueOverdue: {
    color: '#b23923',
  },
  progressTrack: {
    backgroundColor: '#eef2f6',
    borderRadius: 999,
    height: 10,
    marginTop: 8,
    overflow: 'hidden',
  },
  progressFill: {
    backgroundColor: '#17613a',
    borderRadius: 999,
    height: '100%',
  },
  progressFillOverdue: {
    backgroundColor: '#d94f36',
  },
  cardActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginTop: 18,
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#1f2933',
    borderRadius: 8,
    justifyContent: 'center',
    minHeight: 42,
    paddingHorizontal: 16,
  },
  primaryButtonText: {
    color: '#ffffff',
    fontSize: 15,
    fontWeight: '700',
  },
  secondaryButton: {
    alignItems: 'center',
    backgroundColor: '#ffffff',
    borderColor: '#d5d0c8',
    borderRadius: 8,
    borderWidth: 1,
    justifyContent: 'center',
    minHeight: 42,
    paddingHorizontal: 14,
  },
  secondaryButtonText: {
    color: '#374151',
    fontSize: 14,
    fontWeight: '700',
  },
  doneButton: {
    alignItems: 'center',
    backgroundColor: '#17613a',
    borderRadius: 8,
    justifyContent: 'center',
    minHeight: 42,
    paddingHorizontal: 14,
  },
  doneButtonText: {
    color: '#ffffff',
    fontSize: 14,
    fontWeight: '700',
  },
  smallButton: {
    alignItems: 'center',
    backgroundColor: '#eef2f6',
    borderRadius: 8,
    justifyContent: 'center',
    minHeight: 42,
    paddingHorizontal: 14,
  },
  smallButtonText: {
    color: '#374151',
    fontSize: 14,
    fontWeight: '700',
  },
  deleteButton: {
    alignItems: 'center',
    backgroundColor: '#fff0ed',
    borderRadius: 8,
    justifyContent: 'center',
    minHeight: 42,
    paddingHorizontal: 14,
  },
  deleteButtonText: {
    color: '#b23923',
    fontSize: 14,
    fontWeight: '700',
  },
  modalOverlay: {
    flex: 1,
    justifyContent: 'flex-end',
    backgroundColor: 'rgba(17, 24, 39, 0.28)',
  },
  modalPanel: {
    backgroundColor: '#ffffff',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    padding: 20,
    paddingBottom: 34,
  },
  importPanel: {
    backgroundColor: '#ffffff',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    maxHeight: '82%',
    padding: 20,
    paddingBottom: 34,
  },
  modalTitle: {
    color: '#111827',
    fontSize: 21,
    fontWeight: '800',
    marginBottom: 18,
  },
  label: {
    color: '#374151',
    fontSize: 14,
    fontWeight: '700',
    marginBottom: 8,
    marginTop: 10,
  },
  input: {
    backgroundColor: '#f9fafb',
    borderColor: '#d5d0c8',
    borderRadius: 8,
    borderWidth: 1,
    color: '#111827',
    fontSize: 17,
    minHeight: 48,
    paddingHorizontal: 12,
  },
  intervalRow: {
    flexDirection: 'row',
    gap: 10,
  },
  intervalField: {
    alignItems: 'center',
    flex: 1,
    flexDirection: 'row',
    gap: 8,
  },
  intervalUnit: {
    color: '#374151',
    fontSize: 15,
    fontWeight: '700',
  },
  textArea: {
    backgroundColor: '#f9fafb',
    borderColor: '#d5d0c8',
    borderRadius: 8,
    borderWidth: 1,
    color: '#111827',
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace', default: undefined }),
    fontSize: 13,
    minHeight: 240,
    padding: 12,
  },
  exportBox: {
    backgroundColor: '#f9fafb',
    borderColor: '#d5d0c8',
    borderRadius: 8,
    borderWidth: 1,
    maxHeight: 360,
    padding: 12,
  },
  exportText: {
    color: '#111827',
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace', default: undefined }),
    fontSize: 13,
    lineHeight: 19,
  },
  modalActions: {
    flexDirection: 'row',
    gap: 10,
    justifyContent: 'flex-end',
    marginTop: 18,
  },
});
