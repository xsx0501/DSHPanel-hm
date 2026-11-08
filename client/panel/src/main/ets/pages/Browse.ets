import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { PanelStore } from '../store/PanelStore';
import { PanelApi } from '../net/PanelApi';
import { PanelWebBridge } from '../web/PanelWebBridge';
import { PanelTelemetry, TelemetryHub } from '../domain/TelemetryHub';
import { Theme } from '../theme/Theme';

/**
 * ArkWeb container (Mod-WebBridge, docs/design.md §7.4).
 *
 * DSH authenticates browsers with a signed cookie minted only by `GET /?token=…`,
 * so the container performs that exchange itself: the launch token travels as a
 * one-shot query parameter, the 302 lands on the clean URL, and every later
 * navigation rides the cookie inside the WebView's own cookie store.
 *
 * JSBridge / injection / Handover are the next layer; this page deliberately
 * keeps JavaScript access on but exposes no proxy yet.
 */
@Entry
@Component
struct Browse {
  private controller: webview.WebviewController = new webview.WebviewController();
  private store: PanelStore | null = null;
  private bridge: PanelWebBridge | null = null;
  private hub: TelemetryHub = TelemetryHub.get();
  @State private status: string = '准备中…';
  @State private ready: boolean = false;
  @State private target: string = '';
  /** The page always owns the screen; the flag is kept for future chrome toggles. */
  @State private immersive: boolean = true;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.store = new PanelStore(context);
    this.prepare();
  }

  private async prepare(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const baseUrl: string = await this.store.loadBaseUrl();
    if (baseUrl.length === 0) {
      this.status = '还没有节点，请先在主页面导入链接';
      return;
    }
    const startup: string = await this.store.loadStartupToken();
    const token: string = await this.store.loadDeviceToken();
    if (token.length > 0) {
      const api: PanelApi = new PanelApi(baseUrl);
      api.setDeviceToken(token);
      this.bridge = new PanelWebBridge(api, (js: string) => {
        this.runJs(js);
      });
    }
    if (startup.length > 0) {
      // Token exchange inside the WebView: cookie is set by the 302 response.
      this.target = `${baseUrl}/?token=${encodeURIComponent(startup)}`;
      this.status = '正在用启动令牌换取登录态…';
    } else {
      this.target = baseUrl;
      this.status = '已保存的启动令牌缺失，尝试直接打开（可能要求重新导入）';
    }
    this.ready = true;
  }

  private runJs(script: string): void {
    try {
      // Callback form: the single-argument form throws 401 Invalid input parameter
      // on this SDK and the throw is fatal for the page.
      this.controller.runJavaScript(script, (error: BusinessError, result: string) => {
        if (error) {
          this.status = `注入失败 ${error.code}`;
        } else if (result.length > 0) {
          this.status = `脚本返回：${result.substring(0, 32)}`;
        }
      });
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.status = `注入异常 ${businessError.code}`;
    }
  }

  /** Namespace + callback hooks the page can rely on (single line: no comments). */
  private get bootstrapScript(): string {
    return 'window.__DSH_PANEL__={version:1,' +
      'onDecision:function(a,d,o){window.dshBridge&&window.dshBridge.log("decision "+a+" "+d+" "+o);},' +
      'onAbort:function(s,o){window.dshBridge&&window.dshBridge.log("abort "+s+" "+o);},' +
      'onState:function(st){window.dshBridge&&window.dshBridge.log("push "+st.status+" approval="+st.approvalCount);}};';
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.bg)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
      if (this.ready) {
        Stack({ alignContent: Alignment.TopEnd }) {
        Web({ src: this.target, controller: this.controller })
          // Let the page see prefers-color-scheme from the system, and force a dark
          // rendering when the page ships no dark styles of its own.
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(true)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(false)
          .imageAccess(true)
          .onlineImageAccess(true)
          .mixedMode(MixedMode.None)
          .zoomAccess(false)
          .onControllerAttached(() => {
            if (this.bridge !== null) {
              try {
                this.controller.registerJavaScriptProxy(
                  this.bridge,
                  'dshBridge',
                  ['info', 'state', 'decide', 'abort', 'log']
                );
              } catch (error) {
                const businessError: BusinessError = error as BusinessError;
                this.status = `JSBridge 注册失败 ${businessError.code}`;
              }
            }
          })
          .onPageBegin((event: OnPageBeginEvent) => {
            this.status = `加载中：${event.url.substring(0, 48)}`;
          })
          .onPageEnd((event: OnPageEndEvent) => {
            this.status = `已加载：${event.url.substring(0, 48)}`;
            // Self-test: proves the proxy is reachable from page JS. Telemetry is
            // pulled by the page via dshBridge.state() — this ArkWeb build runs
            // runJavaScript in a world where window globals do not persist, so a
            // push-based namespace never sticks.
            this.runJs(`window.dshBridge && window.dshBridge.log('bridge-ok ' + window.dshBridge.info());`);
            this.runJs(`window.dshBridge && window.dshBridge.log('state ' + window.dshBridge.state());`);
          })
          .onSslErrorEventReceive((event: OnSslErrorEventReceiveEvent) => {
            // Never accept a bad certificate silently; DSH deployments should use
            // a trusted chain (see design §7.1.8 for the CA import path).
            event.handler.handleCancel();
            this.status = `证书校验失败：${event.error}`;
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            this.status = `加载失败：${event.error.getErrorInfo()}`;
          })
          .width('100%')
          .height('100%')

          // Fullscreen by default: only two tiny ghost buttons stay on top of the
          // page, so leaving and reloading never needs the old 48px bar.
          Row() {
            Text('‹')
              .fontSize(24)
              .fontColor(Theme.textPrimary)
              .width(32)
              .height(32)
              .textAlign(TextAlign.Center)
              .borderRadius(16)
              .backgroundColor(Theme.glassStrong)
              .onClick(() => {
                router.back();
              })
            Blank()
            Text('↻')
              .fontSize(16)
              .fontColor(Theme.textPrimary)
              .width(32)
              .height(32)
              .textAlign(TextAlign.Center)
              .borderRadius(16)
              .backgroundColor(Theme.glassStrong)
              .onClick(() => {
                try {
                  this.controller.refresh();
                } catch (error) {
                  const businessError: BusinessError = error as BusinessError;
                  this.status = `刷新失败 ${businessError.code}`;
                }
              })
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8 })
          .opacity(0.86)
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        Text(this.status)
          .fontSize(13)
          .width('100%')
          .padding(16)
      }
      }
      .width('100%')
      .height('100%')
      .padding({ top: 38 })
    }
    .width('100%')
    .height('100%')
  }
}
