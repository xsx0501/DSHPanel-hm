import { notificationManager } from '@kit.NotificationKit';
import { common, Want, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * L0 carrier: the plain progress/approval notification (docs/design.md §7.3.4).
 *
 * This carrier needs no special permission, so it stays usable when the ball and
 * the float window are unavailable — that is the whole point of L0.
 *
 * Scope note: action buttons (Allow/Reject straight from the notification shade)
 * are deferred until the WantAgent typing in this toolchain is pinned; for now a
 * tap opens the app, where the approval card is already handled.
 */
export interface ProgressInfo {
  title: string;
  text: string;
}

export class NotificationPresenter {
  private context: common.UIAbilityContext;
  private baseId: number = 2000;
  private slotReady: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** Ask the user once; publishing fails with 1600004 until this is granted. */
  async requestEnable(): Promise<boolean> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (enabled) {
        return true;
      }
      await notificationManager.requestEnableNotification(this.context);
      return await notificationManager.isNotificationEnabled();
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] requestEnableNotification failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }

  async ensureSlot(): Promise<void> {
    if (this.slotReady) {
      return;
    }
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
    } catch (error) {
      // Existing slot: harmless.
    }
    this.slotReady = true;
  }

  private async openAppAgent(extra?: Record<string, Object>): Promise<Object | undefined> {
    try {
      const want: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name
      };
      if (extra !== undefined) {
        want.parameters = extra;
      }
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] wantAgent failed: ${businessError.code} ${businessError.message}`);
      return undefined;
    }
  }

  /** Standing progress notification; stable id per key so updates replace it. */
  async publishProgress(key: string, info: ProgressInfo): Promise<boolean> {
    await this.ensureSlot();
    const agent: Object | undefined = await this.openAppAgent();
    if (agent === undefined) {
      return false;
    }
    const request: notificationManager.NotificationRequest = {
      id: this.idFor(key),
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: info.title, text: info.text }
      },
      wantAgent: agent,
      isOngoing: true
    } as notificationManager.NotificationRequest;
    try {
      await notificationManager.publish(request);
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] publish progress failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }

  /**
   * A persistent, tappable entry back to the panel.
   *
   * Background launch of our own ability needs an ACL permission that is not
   * grantable here, so the notification is the supported entry point: the system
   * performs the launch when the user taps it.
   */
  async publishEntry(text: string): Promise<boolean> {
    await this.ensureSlot();
    const agent: Object | undefined = await this.openAppAgent();
    if (agent === undefined) {
      return false;
    }
    const request: notificationManager.NotificationRequest = {
      id: this.idFor('entry'),
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: 'DSH 面板', text: text }
      },
      wantAgent: agent,
      isOngoing: true
    } as notificationManager.NotificationRequest;
    try {
      await notificationManager.publish(request);
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] publish entry failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }
  /** Approval notification with Allow / Reject buttons (decision travels as Want params). */
  async publishApproval(approvalId: string, toolName: string, preview: string): Promise<boolean> {
    await this.ensureSlot();
    const open: Object | undefined = await this.openAppAgent();
    const allow: Object | undefined = await this.openAppAgent({
      'panelDecision': 'APPROVE',
      'panelApprovalId': approvalId
    });
    const reject: Object | undefined = await this.openAppAgent({
      'panelDecision': 'REJECT',
      'panelApprovalId': approvalId
    });
    if (open === undefined || allow === undefined || reject === undefined) {
      return false;
    }
    const buttons: Array<notificationManager.NotificationActionButton> = [
      { title: '允许', wantAgent: allow } as notificationManager.NotificationActionButton,
      { title: '拒绝', wantAgent: reject } as notificationManager.NotificationActionButton
    ];
    const request: notificationManager.NotificationRequest = {
      id: this.idFor(approvalId),
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: `Agent 请求执行敏感操作（${toolName}）`,
          text: preview.length > 60 ? `${preview.substring(0, 58)}…` : preview
        }
      },
      wantAgent: open,
      actionButtons: buttons
    } as notificationManager.NotificationRequest;
    try {
      await notificationManager.publish(request);
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] publish approval failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }

  async cancel(key: string): Promise<void> {
    try {
      await notificationManager.cancel(this.idFor(key));
    } catch {
      // Already gone.
    }
  }

  private idFor(key: string): number {
    let hash: number = 0;
    for (let i = 0; i < key.length; i++) {
      hash = (hash * 31 + key.charCodeAt(i)) % 100000;
    }
    return this.baseId + hash;
  }
}
