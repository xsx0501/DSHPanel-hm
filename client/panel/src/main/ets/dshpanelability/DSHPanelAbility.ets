import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class DSHPanelAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    this.captureDeepLink(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.captureDeepLink(want);
  }

  /** A `dsh://connect?...` launch or a notification button is staged for the page. */
  private captureDeepLink(want: Want): void {
    const parameters: Record<string, Object> | undefined = want.parameters;
    if (parameters !== undefined) {
      const decision: string = `${parameters['panelDecision'] ?? ''}`;
      const approvalId: string = `${parameters['panelApprovalId'] ?? ''}`;
      if (decision.length > 0 && approvalId.length > 0) {
        AppStorage.setOrCreate<string>('pendingDecision', `${approvalId}|${decision}`);
        hilog.info(DOMAIN, 'testTag', 'notification decision staged: %{public}s', decision);
        return;
      }
    }
    const uri: string = want.uri ?? '';
    if (uri.length === 0) {
      return;
    }
    hilog.info(DOMAIN, 'testTag', 'deep link staged: %{public}s', uri.substring(0, 48));
    AppStorage.setOrCreate<string>('pendingImportUrl', uri);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // Immersive layout: content draws under the system bars and the page supplies
    // its own frosted surfaces, so the bars stay transparent.
    try {
      windowStage.getMainWindow().then((mainWindow: window.Window) => {
        mainWindow.setWindowLayoutFullScreen(true).catch(() => {});
        mainWindow.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          statusBarContentColor: '#182431',
          navigationBarColor: '#00000000',
          navigationBarContentColor: '#182431'
        }).catch(() => {});
        mainWindow.setWindowBackgroundColor('#F2F3F5');
      }).catch(() => {});
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to style system bars: %{public}s', JSON.stringify(err));
    }

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}