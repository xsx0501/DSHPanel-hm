import { floatingBall } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * L1 carrier: the system floating ball (docs/design.md §7.3.5).
 *
 * `FloatingBallParams` only carries template / title / content / icon / colors —
 * there is no custom drawing — so the "ring-like progress" is approximated with a
 * two-line text pair: metrics on the title line, session hint on the content line.
 * Templates cannot be changed by `update`, so a template change means stop+start.
 */
export class FloatingBallPresenter {
  private context: common.UIAbilityContext;
  private controller: floatingBall.FloatingBallController | null = null;
  private running: boolean = false;
  private clickHandler: (() => void) | null = null;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  isSupported(): boolean {
    try {
      return canIUse('SystemCapability.Window.SessionManager') && floatingBall.isFloatingBallEnabled();
    } catch {
      return false;
    }
  }

  /** Two-line content: `title` is the big line, `content` the small one. */
  async show(title: string, content: string): Promise<boolean> {
    if (!this.isSupported()) {
      return false;
    }
    const controller: floatingBall.FloatingBallController | null = await this.ensureController();
    if (controller === null) {
      return false;
    }
    try {
      const params: floatingBall.FloatingBallParams = this.params(title, content);
      if (!this.running) {
        await controller.startFloatingBall(params);
        this.running = true;
        this.bindClick();
      } else {
        await controller.updateFloatingBall(params);
      }
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] floating ball failed: ${businessError.code} ${businessError.message}`);
      return false;
    }
  }

  /** The ball is the main entry point, so a tap must do something useful. */
  onClick(handler: () => void): void {
    this.clickHandler = handler;
    this.bindClick();
  }

  /**
   * Drop our tap handler so the system's own ball-to-float-view expansion can run
   * (it only happens when the app does not consume the click).
   */
  clearClick(): void {
    this.clickHandler = null;
    if (this.controller === null) {
      return;
    }
    try {
      this.controller.off('click');
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] floating ball click unbind failed: ${businessError.code}`);
    }
  }
  private bindClick(): void {
    if (this.controller === null || this.clickHandler === null) {
      return;
    }
    try {
      this.controller.off('click');
      this.controller.on('click', () => {
        if (this.clickHandler !== null) {
          this.clickHandler();
        }
      });
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] floating ball click binding failed: ${businessError.code}`);
    }
  }

  /** Create the controller without starting it — `floatView.bind` needs this. */
  async ensureController(): Promise<floatingBall.FloatingBallController | null> {
    if (!this.isSupported()) {
      return null;
    }
    try {
      if (this.controller === null) {
        this.controller = await floatingBall.create({ context: this.context });
      }
      return this.controller;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] floating ball create failed: ${businessError.code} ${businessError.message}`);
      return null;
    }
  }

  /** Params used both for a standalone ball and for the bound ball. */
  params(title: string, content: string): floatingBall.FloatingBallParams {
    const safeTitle: string = title.length > 16 ? `${title.substring(0, 15)}…` : title;
    const safeContent: string = content.length > 22 ? `${content.substring(0, 21)}…` : content;
    return {
      template: floatingBall.FloatingBallTemplate.EMPHATIC,
      title: safeTitle,
      content: safeContent,
      backgroundColor: '#0A59F7',
      titleColor: '#FFFFFF',
      contentColor: '#D8E6FF'
    };
  }

  isRunning(): boolean {
    return this.running;
  }

  async hide(): Promise<void> {
    if (this.controller === null) {
      return;
    }
    try {
      await this.controller.stopFloatingBall();
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] stop floating ball failed: ${businessError.code}`);
    }
    this.controller = null;
    this.running = false;
  }
}
