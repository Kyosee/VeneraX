import { workScheduler } from '@kit.BackgroundTasksKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import deviceInfo from '@ohos.deviceInfo';
import { Any, MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';

export const FOLLOW_WORK_ID = 336;
export const FOLLOW_DAILY_WORK_ID = 337;
export const FOLLOW_WORK_ABILITY = 'FollowUpdatesAbility';

export class FollowSchedulerService implements MethodCallHandler {
  private tail: Promise<void> = Promise.resolve();
  private bundleName: string;
  private filesDir: string;
  private static uiLease?: fs.File;

  constructor(bundleName: string, filesDir: string) {
    this.bundleName = bundleName;
    this.filesDir = filesDir;
  }

  private static async registered(workId: number): Promise<workScheduler.WorkInfo | undefined> {
    try {
      return await workScheduler.getWorkStatus(workId);
    } catch (_) {
      return undefined;
    }
  }

  private static async withScheduleLock(filesDir: string, update: () => Promise<void>): Promise<void> {
    // The UI and the scheduler extension update the same OS registrations from separate processes.
    const file = fs.openSync(`${filesDir}/.follow-schedule-config.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    try {
      await file.lock(true);
      await update();
    } finally {
      fs.closeSync(file);
    }
  }

  static async rollDailyForward(filesDir: string): Promise<void> {
    if (deviceInfo.sdkApiVersion < 22) return;
    await FollowSchedulerService.withScheduleLock(filesDir, async (): Promise<void> => {
      const regular = await FollowSchedulerService.registered(FOLLOW_WORK_ID);
      const minute = regular?.parameters?.['fixedMinute'];
      if (regular === undefined || typeof minute !== 'number') return;
      const daily = await FollowSchedulerService.registered(FOLLOW_DAILY_WORK_ID);
      FollowSchedulerService.configureJob(regular.bundleName, FOLLOW_DAILY_WORK_ID, daily, true, minute, true);
    });
  }

  private static configureJob(bundleName: string, workId: number, existing: workScheduler.WorkInfo | undefined,
    enabled: boolean, fixedMinute?: number, afterWake: boolean = false): void {
    if (!enabled) {
      if (existing !== undefined) workScheduler.stopWork(existing, true);
      return;
    }
    const now = new Date();
    const daily = workId === FOLLOW_DAILY_WORK_ID;
    const offset = now.getTimezoneOffset();
    const target = new Date(now.getTime());
    if (daily && fixedMinute !== undefined) {
      target.setHours(Math.floor(fixedMinute / 60), fixedMinute % 60, 0, 0);
      if (target.getTime() < now.getTime() || (afterWake && target.getTime() === now.getTime())) {
        target.setDate(target.getDate() + 1);
      }
    }
    if (existing !== undefined) {
      const params = existing.parameters;
      if (params?.['fixedMinute'] === fixedMinute) {
        if (!daily) return;
        const previousDay = params?.['targetDay'];
        // A UI settings refresh must not withdraw today's still-pending wake.
        const pendingToday = !afterWake && previousDay === now.toDateString();
        if (params?.['utcOffset'] === offset && (previousDay === target.toDateString() || pendingToday)) return;
      }
      workScheduler.stopWork(existing, true);
    }
    const job: workScheduler.WorkInfo = {
      workId: workId,
      bundleName: bundleName,
      abilityName: FOLLOW_WORK_ABILITY,
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isPersisted: true,
      isRepeat: true,
      repeatCycleTime: (daily ? 24 : 2) * 60 * 60 * 1000
    };
    if (fixedMinute !== undefined) {
      job.parameters = { 'fixedMinute': fixedMinute };
      if (daily) {
        job.earliestStartTime = target.getTime() - now.getTime();
        job.parameters['utcOffset'] = offset;
        job.parameters['targetDay'] = target.toDateString();
      }
    }
    workScheduler.startWork(job);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'configure' && call.method !== 'acquireUiData') {
      result.notImplemented();
      return;
    }
    this.tail = this.tail.then(async (): Promise<void> => {
      try {
        if (call.method === 'acquireUiData') {
          if (FollowSchedulerService.uiLease === undefined) {
            const regular = await FollowSchedulerService.registered(FOLLOW_WORK_ID);
            const daily = await FollowSchedulerService.registered(FOLLOW_DAILY_WORK_ID);
            for (const job of [regular, daily]) {
              if (job !== undefined) {
                try { workScheduler.stopWork(job, false); } catch (_) {}
              }
            }
            const lease = fs.openSync(`${this.filesDir}/.follow-scheduler.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
            try {
              await lease.lock(true);
              // ponytail: the UI owns data until process exit; frozen UI sessions
              // defer extension checks until reopening or process reclamation.
              FollowSchedulerService.uiLease = lease;
            } catch (_) {
              fs.closeSync(lease);
              throw new Error('Unable to acquire data access');
            }
          }
        } else {
          const enabled: Any = call.argument('enabled');
          if (typeof enabled !== 'boolean') throw new Error('Invalid schedule');
          const minute: Any = call.argument('fixedMinute');
          if (minute != null && (typeof minute !== 'number' || !Number.isInteger(minute) ||
            minute < 0 || minute >= 24 * 60)) {
            throw new Error('Invalid fixed time');
          }
          const fixedMinute = typeof minute === 'number' && deviceInfo.sdkApiVersion >= 22 ? minute : undefined;
          await FollowSchedulerService.withScheduleLock(this.filesDir, async (): Promise<void> => {
            const regular = await FollowSchedulerService.registered(FOLLOW_WORK_ID);
            const daily = await FollowSchedulerService.registered(FOLLOW_DAILY_WORK_ID);
            FollowSchedulerService.configureJob(this.bundleName, FOLLOW_WORK_ID, regular, enabled, fixedMinute);
            FollowSchedulerService.configureJob(this.bundleName, FOLLOW_DAILY_WORK_ID, daily,
              enabled && fixedMinute !== undefined, fixedMinute);
          });
        }
        result.success(null);
      } catch (_) {
        result.error('FOLLOW_SCHEDULE_UNAVAILABLE', 'Unable to update background schedule.', null);
      }
    });
  }
}
