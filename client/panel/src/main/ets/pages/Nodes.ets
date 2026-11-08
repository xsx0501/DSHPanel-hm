import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { PanelStore } from '../store/PanelStore';
import { PanelApi } from '../net/PanelApi';
import { ImportIntent, NodeInfo, PairResponse } from '../model/PanelTypes';
import { Theme } from '../theme/Theme';
import { scanBarcode, scanCore } from '@kit.ScanKit';

/**
 * Node management (docs/design.md §6.3 / §7.1.5).
 *
 * One phone can hold several DSH deployments; each keeps its own device token in
 * a per-node ASSET alias, so switching never re-pairs and never leaks a token to
 * the wrong host.
 */
@Entry
@Component
struct Nodes {
  @State private nodes: NodeInfo[] = [];
  @State private activeId: string = '';
  @State private input: string = '';
  @State private status: string = '正在读取节点…';
  @State private busy: boolean = false;
  private store: PanelStore | null = null;

  aboutToAppear(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.store = new PanelStore(context);
    this.reload();
  }

  onPageShow(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    if (this.store === null) {
      return;
    }
    this.nodes = await this.store.loadNodes();
    this.activeId = await this.store.activeNodeId();
    this.status = this.nodes.length === 0 ? '还没有节点，粘贴链接添加' : `${this.nodes.length} 个节点`;
  }

  private async activate(node: NodeInfo): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.setActiveNodeId(node.id);
    await this.store.saveBaseUrl(node.baseUrl);
    const token: string = await this.store.loadDeviceTokenFor(node.id);
    if (token.length > 0) {
      await this.store.saveDeviceToken(token);
    }
    const startup: string = await this.store.loadStartupTokenFor(node.id);
    if (startup.length > 0) {
      await this.store.saveStartupToken(startup);
    }
    this.activeId = node.id;
    this.status = `已切换到 ${node.name}`;
    router.back();
  }

  private async remove(node: NodeInfo): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.removeNode(node.id, this.nodes);
    await this.reload();
    this.status = `已删除 ${node.name}`;
  }

  private parse(raw: string): ImportIntent | null {
    const text: string = raw.trim();
    if (text.length === 0) {
      return null;
    }
    if (text.startsWith('dsh://')) {
      const endpoint: RegExpMatchArray | null = text.match(/[?&]endpoint=([^&]+)/);
      const token: RegExpMatchArray | null = text.match(/[?&]token=([A-Za-z0-9._~+/=-]+)/);
      if (endpoint === null || token === null) {
        return null;
      }
      return { baseUrl: decodeURIComponent(endpoint[1]).replace(/\/+$/, ''), startupToken: token[1] };
    }
    const tokenMatch: RegExpMatchArray | null = text.match(/[?&]token=([A-Za-z0-9._~+/=-]+)/);
    const startupToken: string = tokenMatch === null ? text : tokenMatch[1];
    let baseUrl: string = '';
    if (text.startsWith('http://') || text.startsWith('https://')) {
      const cut: number = text.indexOf('?');
      baseUrl = cut < 0 ? text : text.substring(0, cut);
    } else if (!text.includes('://') && text.includes('.')) {
      baseUrl = `https://${text}`;
    }
    if (baseUrl.length === 0) {
      return null;
    }
    return { baseUrl: baseUrl.replace(/\/+$/, ''), startupToken: startupToken };
  }

  /** Scan the QR that dsh web prints; fills the import field. */
  private async scan(): Promise<void> {
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE, scanCore.ScanType.ALL],
        enableMultiMode: false,
        enableAlbum: true
      };
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const result = await scanBarcode.startScanForResult(context, options);
      if (result.originalValue.length > 0) {
        this.input = result.originalValue;
        this.status = '已识别二维码，点击「添加节点」完成配对';
      }
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.status = `扫码取消或失败（${businessError.code ?? 0}）`;
    }
  }
  private async addNode(): Promise<void> {
    if (this.store === null || this.busy) {
      return;
    }
    const intent: ImportIntent | null = this.parse(this.input);
    if (intent === null) {
      this.status = '链接无效：粘贴 dsh://connect?… 或 https://host/?token=…';
      return;
    }
    this.busy = true;
    this.status = '正在配对…';
    try {
      const api: PanelApi = new PanelApi(intent.baseUrl);
      const pair: PairResponse = await api.pairWithToken(intent.startupToken, 'HarmonyOS 面板');
      if (!pair.ok || pair.deviceToken === undefined) {
        this.status = `配对失败：${pair.code ?? 'UNKNOWN'}`;
        return;
      }
      let existing: NodeInfo | undefined = undefined;
      for (const item of this.nodes) {
        if (item.baseUrl === intent.baseUrl) {
          existing = item;
          break;
        }
      }
      const node: NodeInfo = existing !== undefined ? existing : {
        id: `n${Date.now()}`,
        name: PanelStore.hostOf(intent.baseUrl),
        baseUrl: intent.baseUrl,
        lastUsedAt: Date.now()
      };
      node.lastUsedAt = Date.now();
      await this.store.saveDeviceTokenFor(node.id, pair.deviceToken);
      await this.store.saveStartupTokenFor(node.id, intent.startupToken);
      if (existing === undefined) {
        this.nodes.push(node);
      }
      await this.store.saveNodes(this.nodes);
      await this.activate(node);
      this.input = '';
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.status = `添加失败：${businessError.code ?? ''} ${businessError.message ?? ''}`;
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('返回')
          .fontSize(14)
          .fontColor(Theme.brand)
          .onClick(() => {
            router.back();
          })
        Text('节点')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.textPrimary)
          .layoutWeight(1)
        Text(this.busy ? '处理中…' : '')
          .fontSize(12)
          .fontColor(Theme.textTertiary)
      }
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding, top: 12, bottom: 8 })

      Text(this.status)
        .fontSize(12)
        .fontColor(Theme.textSecondary)
        .width('100%')
        .padding({ left: Theme.pagePadding, right: Theme.pagePadding, bottom: 8 })

      List({ space: 8 }) {
        ForEach(this.nodes, (node: NodeInfo) => {
          ListItem() {
            Row({ space: 10 }) {
              Circle({ width: 8, height: 8 }).fill(node.id === this.activeId ? Theme.success : Theme.divider)
              Column({ space: 3 }) {
                Text(node.name)
                  .fontSize(15)
                  .fontColor(Theme.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(node.baseUrl)
                  .fontSize(11)
                  .fontColor(Theme.textTertiary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (node.id === this.activeId) {
                Text('当前')
                  .fontSize(11)
                  .fontColor(Theme.brand)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                  .backgroundColor(Theme.brandSoft)
                  .borderRadius(8)
              } else {
                Text('切换')
                  .fontSize(12)
                  .fontColor(Theme.brand)
                  .onClick(() => {
                    this.activate(node);
                  })
              }
              Text('删除')
                .fontSize(12)
                .fontColor(Theme.danger)
                .onClick(() => {
                  this.remove(node);
                })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.card)
            .borderRadius(Theme.radiusCard)
          }
        }, (node: NodeInfo) => node.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: Theme.pagePadding, right: Theme.pagePadding })
      .scrollBar(BarState.Off)

      Column({ space: 10 }) {
        Row({ space: 8 }) {
          TextInput({ text: this.input, placeholder: 'dsh://connect?endpoint=…&token=…' })
            .height(44)
            .fontSize(13)
            .onChange((value: string) => {
              this.input = value;
            })
            .layoutWeight(1)
          Text('扫码')
            .fontSize(14)
            .fontColor(Theme.brand)
            .height(44)
            .padding({ left: 14, right: 14 })
            .backgroundColor(Theme.brandSoft)
            .borderRadius(12)
            .onClick(() => {
              this.scan();
            })
        }
        .width('100%')
        Text('添加节点')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.textOnBrand)
          .textAlign(TextAlign.Center)
          .height(44)
          .width('100%')
          .backgroundColor(this.busy ? Theme.textTertiary : Theme.brand)
          .borderRadius(12)
          .onClick(() => {
            this.addNode();
          })
      }
      .width('100%')
      .padding(Theme.pagePadding)
      .backgroundColor(Theme.card)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
