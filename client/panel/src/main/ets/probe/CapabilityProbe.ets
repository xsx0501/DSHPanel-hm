import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { floatingBall, floatView } from '@kit.ArkUI';
import { liveViewManager } from '@kit.LiveViewKit';

export interface CapabilityReport {
  apiLevel: string;
  sessionManager: boolean;
  floatingBallEnabled: boolean;
  floatViewEnabled: boolean;
  floatViewAvailable: boolean;
  liveViewEnabled: boolean;
  permissionFloatBall: boolean;
  permissionFloatView: boolean;
  permissionKeepAlive: boolean;
  permissionKeepAliveSystem: boolean;
  notes: string[];
}

/**
 * Runtime capability ladder probe (docs/design.md §3.4).
 *
 * Everything here is a *question*, never an assumption: the app must work at L0
 * (notification only) and light up higher rungs only when the device and the
 * signing profile actually allow it.
 */
export class CapabilityProbe {
  static async probe(context: common.UIAbilityContext): Promise<CapabilityReport> {
    const notes: string[] = [];
    const report: CapabilityReport = {
      apiLevel: `${deviceInfo.sdkApiVersion ?? '?'}`,
      sessionManager: false,
      floatingBallEnabled: false,
      floatViewEnabled: false,
      floatViewAvailable: false,
      liveViewEnabled: false,
      permissionFloatBall: false,
      permissionFloatView: false,
      permissionKeepAlive: false,
      permissionKeepAliveSystem: false,
      notes: notes
    };

    try {
      report.sessionManager = canIUse('SystemCapability.Window.SessionManager');
    } catch {
      notes.push('canIUse(SystemCapability.Window.SessionManager) threw');
    }

    if (report.sessionManager) {
      try {
        report.floatingBallEnabled = floatingBall.isFloatingBallEnabled();
      } catch (error) {
        notes.push(`isFloatingBallEnabled failed: ${error}`);
      }
      try {
        report.floatViewEnabled = floatView.isFloatViewEnabled();
        report.floatViewAvailable = true;
      } catch (error) {
        notes.push(`isFloatViewEnabled failed: ${error}`);
      }
    } else {
      notes.push('SessionManager unavailable: L1/L2 cannot be used on this device');
    }

    try {
      report.liveViewEnabled = await liveViewManager.isLiveViewEnabled();
    } catch (error) {
      notes.push(`isLiveViewEnabled failed: ${error}`);
    }

    const tokenId: number = context.applicationInfo.accessTokenId;
    const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    report.permissionFloatBall = await CapabilityProbe.granted(manager, tokenId, 'ohos.permission.USE_FLOAT_BALL');
    report.permissionFloatView = await CapabilityProbe.granted(manager, tokenId, 'ohos.permission.FLOAT_VIEW');
    report.permissionKeepAlive = await CapabilityProbe.granted(manager, tokenId, 'ohos.permission.KEEP_BACKGROUND_RUNNING');
    report.permissionKeepAliveSystem =
      await CapabilityProbe.granted(manager, tokenId, 'ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM');

    if (!report.permissionFloatBall) {
      notes.push('USE_FLOAT_BALL not granted: L1/L2 unavailable (needs ACL profile)');
    }
    if (!report.permissionKeepAliveSystem) {
      notes.push('KEEP_BACKGROUND_RUNNING_SYSTEM not granted: fall back to DATA_TRANSFER keep-alive');
    }
    return report;
  }

  /**
   * `FLOAT_VIEW` is user_grant: declaring it in module.json5 is not enough, the
   * app must ask at runtime (docs/design.md §3.3).
   */
  static async requestFloatView(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(context, ['ohos.permission.FLOAT_VIEW']);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch {
      return false;
    }
  }

  private static async granted(
    manager: abilityAccessCtrl.AtManager,
    tokenId: number,
    permission: Permissions
  ): Promise<boolean> {
    try {
      const status: abilityAccessCtrl.GrantStatus = await manager.checkAccessToken(tokenId, permission);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch {
      return false;
    }
  }
}
