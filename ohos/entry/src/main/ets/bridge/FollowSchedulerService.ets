import { workScheduler } from '@kit.BackgroundTasksKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Any, MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';

export const FOLLOW_WORK_ID = 336;
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

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'configure' && call.method !== 'acquireUiData') {
      result.notImplemented();
      return;
    }
    this.tail = this.tail.then(async (): Promise<void> => {
      try {
        let existing: workScheduler.WorkInfo | undefined;
        try {
          existing = await workScheduler.getWorkStatus(FOLLOW_WORK_ID);
        } catch (_) {
          // No job has been registered on this installation yet.
        }
        if (call.method === 'acquireUiData') {
          if (FollowSchedulerService.uiLease === undefined) {
            if (existing !== undefined) {
              try { workScheduler.stopWork(existing, false); } catch (_) {}
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
          if (!enabled) {
            if (existing !== undefined) workScheduler.stopWork(existing, true);
          } else if (existing === undefined) {
            // The OS may run less often. Per-comic due times remain in Dart.
            workScheduler.startWork({
              workId: FOLLOW_WORK_ID,
              bundleName: this.bundleName,
              abilityName: FOLLOW_WORK_ABILITY,
              networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
              isPersisted: true,
              isRepeat: true,
              repeatCycleTime: 2 * 60 * 60 * 1000
            });
          }
        }
        result.success(null);
      } catch (_) {
        result.error('FOLLOW_SCHEDULE_UNAVAILABLE', 'Unable to update background schedule.', null);
      }
    });
  }
}
