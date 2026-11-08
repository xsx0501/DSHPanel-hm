import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Background keep-alive (docs/design.md §7.3.3).
 *
 * Path 0 `MODE_TASK_KEEPING` is the right fit for an agent that runs for minutes:
 * a plain text notification is enough and it does not need Live View rights.
 * Requires the ACL permission `KEEP_BACKGROUND_RUNNING_SYSTEM`; when it is missing
 * we fall back to the legacy `DATA_TRANSFER` request, and if that also fails the
 * caller must show "background limited" instead of pretending to monitor.
 */
export class KeepAlivePresenter {
  private context: common.UIAbilityContext;
  private running: boolean = false;
  private taskId: number = -1;
  private mode: string = '';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  isRunning(): boolean {
    return this.running;
  }

  getMode(): string {
    return this.mode;
  }

  async start(): Promise<string> {
    if (this.running) {
      return `already:${this.mode}`;
    }
    const bundleName: string = this.context.abilityInfo.bundleName;
    const abilityName: string = this.context.abilityInfo.name;
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: bundleName, abilityName: abilityName }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });

    // Path 0: computing-task keep-alive (needs the ACL permission).
    try {
      const request: backgroundTaskManager.ContinuousTaskRequest = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
      request.wantAgent = agent;
      const info: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(this.context, request);
      this.taskId = info.continuousTaskId ?? -1;
      this.running = true;
      this.mode = 'TASK_KEEPING';
      this.watchCancel();
      return 'TASK_KEEPING';
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.warn(`[panel] TASK_KEEPING failed: ${businessError.code} ${businessError.message}`);
    }

    // Path A: legacy data-transfer keep-alive (normal permission).
    try {
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      );
      this.running = true;
      this.mode = 'DATA_TRANSFER';
      this.watchCancel();
      return 'DATA_TRANSFER';
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] DATA_TRANSFER failed: ${businessError.code} ${businessError.message}`);
      this.mode = `failed:${businessError.code}`;
      return this.mode;
    }
  }

  async stop(): Promise<void> {
    if (!this.running) {
      return;
    }
    try {
      if (this.taskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(this.context, this.taskId);
      } else {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
      }
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.warn(`[panel] stop keep-alive failed: ${businessError.code}`);
    }
    this.running = false;
    this.taskId = -1;
    this.mode = '';
  }

  /** The system can revoke the task (low speed / long pause); surface it. */
  private watchCancel(): void {
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        console.warn(`[panel] continuous task cancelled: ${info.reason}`);
        this.running = false;
      });
    } catch {
      // Older builds may not expose the callback; ignore.
    }
  }
}
