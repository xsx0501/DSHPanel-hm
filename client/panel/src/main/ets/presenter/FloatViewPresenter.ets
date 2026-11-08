import { floatView, floatingBall } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * L2 carrier: the system float view bound to the floating ball
 * (docs/design.md §3.2 / §7.3.6).
 *
 * Facts pinned from the SDK and the device:
 *  - `FloatViewTemplateType` has only ROUNDED_RECTANGLE / HORIZONTAL_BAR; the
 *    window content is OUR OWN ArkUI route page, loaded by `setUIContext`.
 *  - The page path must be listed in `main_pages.json`.
 *  - The float view and the ball must be bound BEFORE either starts; `stop()` on
 *    either controller destroys both windows.
 */
export class FloatViewPresenter {
  private context: common.UIAbilityContext;
  private controller: floatView.FloatViewController | null = null;
  private storage: LocalStorage = new LocalStorage();
  private readonly pagePath: string = 'pages/FloatCard';

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** True when the device exposes the API and the user allowed FLOAT_VIEW. */
  static isSupported(): boolean {
    try {
      return canIUse('SystemCapability.Window.SessionManager') && floatView.isFloatViewEnabled();
    } catch {
      return false;
    }
  }

  /** Container state channel: the card page reads `line` / `status` / `preview`. */
  update(state: Record<string, string>): void {
    for (const key of Object.keys(state)) {
      this.storage.setOrCreate<string>(key, state[key]);
    }
  }

  /** Smallest window the system allows for this template. */
  static minSize(): window.Size {
    try {
      const limits: floatView.FloatViewLimits =
        floatView.getFloatViewLimits(floatView.FloatViewTemplateType.ROUNDED_RECTANGLE);
      return limits.minSize;
    } catch {
      return { width: 120, height: 120 };
    }
  }

  /**
   * Start as a small, self-drawn glass block (no system floating ball involved).
   * Must be called while the app is in the foreground, like any float window.
   */
  async startGlass(width: number, height: number): Promise<boolean> {
    if (!FloatViewPresenter.isSupported()) {
      return false;
    }
    try {
      if (this.controller === null) {
        this.controller = await floatView.create({
          context: this.context,
          templateType: floatView.FloatViewTemplateType.ROUNDED_RECTANGLE,
          isConfirmOnClose: false
        });
        await this.controller.setUIContext(this.pagePath, this.storage);
      }
      await this.controller.setWindowSize({ width: width, height: height });
      await this.controller.start();
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] glass block start failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }

  /** Grow into the card, or shrink back into the block. */
  async resize(width: number, height: number): Promise<void> {
    if (this.controller === null) {
      return;
    }
    try {
      await this.controller.setWindowSize({ width: width, height: height });
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] glass block resize failed: ${businessError.code} ${businessError.message}`);
    }
  }

  async start(ballController: floatingBall.FloatingBallController, ballParams: floatingBall.FloatingBallParams): Promise<boolean> {
    if (!FloatViewPresenter.isSupported()) {
      return false;
    }
    try {
      if (this.controller === null) {
        this.controller = await floatView.create({
          context: this.context,
          templateType: floatView.FloatViewTemplateType.ROUNDED_RECTANGLE,
          isConfirmOnClose: false
        });
        await this.controller.setUIContext(this.pagePath, this.storage);
        this.controller.onStateChange((info: floatView.FloatViewStateChangeInfo) => {
          console.info(`[panel] floatView state=${info.state} reason=${info.stopReason}`);
        });
      }
      await floatView.bind(this.controller, ballController, ballParams);
      await this.controller.start();
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] floatView failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }

  /**
   * Show the card on its own, without the floating ball.
   *
   * Binding requires a ball that has NOT started yet (error 1300025 otherwise), so
   * tapping an already-running ball expands this independent window instead.
   */
  async startStandalone(): Promise<boolean> {
    if (!FloatViewPresenter.isSupported()) {
      return false;
    }
    try {
      if (this.controller === null) {
        this.controller = await floatView.create({
          context: this.context,
          templateType: floatView.FloatViewTemplateType.ROUNDED_RECTANGLE,
          isConfirmOnClose: false
        });
        await this.controller.setUIContext(this.pagePath, this.storage);
      }
      await this.controller.start();
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] floatView standalone failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }
  /**
   * Correct L2 wiring: bind the pair *before* either starts.
   * After binding, starting the ball shows the ball, and the system expands the
   * card when the ball is tapped.
   */
  async bindTo(ballController: floatingBall.FloatingBallController,
    ballParams: floatingBall.FloatingBallParams): Promise<boolean> {
    if (!FloatViewPresenter.isSupported()) {
      return false;
    }
    try {
      if (this.controller === null) {
        this.controller = await floatView.create({
          context: this.context,
          templateType: floatView.FloatViewTemplateType.ROUNDED_RECTANGLE,
          isConfirmOnClose: false
        });
        await this.controller.setUIContext(this.pagePath, this.storage);
        this.controller.onStateChange((info: floatView.FloatViewStateChangeInfo) => {
          console.info(`[panel] floatView state=${info.state} reason=${info.stopReason}`);
        });
      }
      await floatView.bind(this.controller, ballController, ballParams);
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] floatView bind failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }
  async stop(): Promise<void> {
    if (this.controller === null) {
      return;
    }
    try {
      await this.controller.stop();
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.warn(`[panel] floatView stop failed: ${businessError.code}`);
    }
    this.controller = null;
  }

  isRunning(): boolean {
    return this.controller !== null;
  }
}
