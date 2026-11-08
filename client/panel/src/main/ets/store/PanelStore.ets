import { asset } from '@kit.AssetStoreKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NodeInfo } from '../model/PanelTypes';

const STORE_NAME: string = 'dsh_panel';
const KEY_BASE_URL: string = 'baseUrl';
const KEY_SESSION: string = 'lastSessionId';
const JOURNAL_KEY: string = 'journal';
const KEY_NODES: string = 'nodes';
const KEY_ACTIVE_NODE: string = 'activeNodeId';
const TOKEN_ALIAS: string = 'dsh_device_token';
const STARTUP_ALIAS: string = 'dsh_startup_token';

/**
 * Local state.
 *
 * The device token is a long-lived credential, so it lives in ASSET (hardware
 * protected) rather than preferences — see docs/design.md §6.2. The endpoint and
 * the last session id are ordinary configuration and stay in preferences.
 */
export class PanelStore {
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  // ── multi-node support (docs/design.md §6.3) ────────────────────────────

  /** Node list, migrated from the legacy single-node keys on first read. */
  async loadNodes(): Promise<NodeInfo[]> {
    const store: preferences.Preferences = await this.prefs();
    const raw: string = await store.get(KEY_NODES, '') as string;
    if (raw.length > 0) {
      try {
        return JSON.parse(raw) as NodeInfo[];
      } catch {
        return [];
      }
    }
    // Migration: an install that predates multi-node keeps working untouched.
    const legacyUrl: string = await this.loadBaseUrl();
    if (legacyUrl.length === 0) {
      return [];
    }
    const legacyToken: string = await this.loadDeviceToken();
    if (legacyToken.length === 0) {
      return [];
    }
    const node: NodeInfo = {
      id: 'n1',
      name: PanelStore.hostOf(legacyUrl),
      baseUrl: legacyUrl,
      lastUsedAt: Date.now()
    };
    await this.saveDeviceTokenFor(node.id, legacyToken);
    const startup: string = await this.loadStartupToken();
    if (startup.length > 0) {
      await this.saveStartupTokenFor(node.id, startup);
    }
    const nodes: NodeInfo[] = [node];
    await this.saveNodes(nodes);
    await this.setActiveNodeId(node.id);
    return nodes;
  }

  async saveNodes(nodes: NodeInfo[]): Promise<void> {
    const store: preferences.Preferences = await this.prefs();
    await store.put(KEY_NODES, JSON.stringify(nodes));
    await store.flush();
  }

  async activeNodeId(): Promise<string> {
    const store: preferences.Preferences = await this.prefs();
    return await store.get(KEY_ACTIVE_NODE, '') as string;
  }

  async setActiveNodeId(id: string): Promise<void> {
    const store: preferences.Preferences = await this.prefs();
    await store.put(KEY_ACTIVE_NODE, id);
    await store.flush();
  }

  /** Per-node credentials live under their own alias so switching is lossless. */
  async saveDeviceTokenFor(nodeId: string, token: string): Promise<void> {
    await this.writeSecret(`dsh_device_token_${nodeId}`, token);
  }

  async loadDeviceTokenFor(nodeId: string): Promise<string> {
    return await this.readSecret(`dsh_device_token_${nodeId}`);
  }

  async saveStartupTokenFor(nodeId: string, token: string): Promise<void> {
    await this.writeSecret(`dsh_startup_token_${nodeId}`, token);
  }

  async loadStartupTokenFor(nodeId: string): Promise<string> {
    return await this.readSecret(`dsh_startup_token_${nodeId}`);
  }

  async removeNode(nodeId: string, nodes: NodeInfo[]): Promise<void> {
    await this.deleteSecret(`dsh_device_token_${nodeId}`);
    await this.deleteSecret(`dsh_startup_token_${nodeId}`);
    const rest: NodeInfo[] = nodes.filter((item: NodeInfo) => item.id !== nodeId);
    await this.saveNodes(rest);
    if ((await this.activeNodeId()) === nodeId) {
      await this.setActiveNodeId(rest.length > 0 ? rest[0].id : '');
    }
  }

  private async writeSecret(alias: string, value: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, PanelStore.toBytes(alias));
    attributes.set(asset.Tag.SECRET, PanelStore.toBytes(value));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attributes);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === 24000003) {
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, PanelStore.toBytes(alias));
        const update: asset.AssetMap = new Map();
        update.set(asset.Tag.SECRET, PanelStore.toBytes(value));
        await asset.update(query, update);
        return;
      }
      throw error as Error;
    }
  }

  private async readSecret(alias: string): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PanelStore.toBytes(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      return PanelStore.fromBytes(results[0].get(asset.Tag.SECRET) as Uint8Array);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === 24000002) {
        return '';
      }
      throw error as Error;
    }
  }

  private async deleteSecret(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PanelStore.toBytes(alias));
    try {
      await asset.remove(query);
    } catch {
      // Absent is fine.
    }
  }

  /** Bare host, for a default node label. */
  static hostOf(url: string): string {
    return url.replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  }

  private async prefs(): Promise<preferences.Preferences> {
    return await preferences.getPreferences(this.context, STORE_NAME);
  }

  async loadBaseUrl(): Promise<string> {
    const store: preferences.Preferences = await this.prefs();
    return await store.get(KEY_BASE_URL, '') as string;
  }

  async saveBaseUrl(url: string): Promise<void> {
    const store: preferences.Preferences = await this.prefs();
    await store.put(KEY_BASE_URL, url);
    await store.flush();
  }

  async loadLastSession(): Promise<string> {
    const store: preferences.Preferences = await this.prefs();
    return await store.get(KEY_SESSION, '') as string;
  }

  async saveLastSession(sessionId: string): Promise<void> {
    const store: preferences.Preferences = await this.prefs();
    await store.put(KEY_SESSION, sessionId);
    await store.flush();
  }

  async saveDeviceToken(token: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, PanelStore.toBytes(TOKEN_ALIAS));
    attributes.set(asset.Tag.SECRET, PanelStore.toBytes(token));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.DATA_LABEL_NORMAL_1, PanelStore.toBytes('dsh'));
    try {
      await asset.add(attributes);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === 24000003) {
        // Already present: overwrite through update (E-1.2 credential hot update).
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, PanelStore.toBytes(TOKEN_ALIAS));
        const update: asset.AssetMap = new Map();
        update.set(asset.Tag.SECRET, PanelStore.toBytes(token));
        await asset.update(query, update);
        return;
      }
      throw error as Error;
    }
  }

  async loadDeviceToken(): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PanelStore.toBytes(TOKEN_ALIAS));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      const secret: asset.Value = results[0].get(asset.Tag.SECRET) as asset.Value;
      return PanelStore.fromBytes(secret as Uint8Array);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === 24000002) {
        return '';
      }
      throw error as Error;
    }
  }

  async clearDeviceToken(): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PanelStore.toBytes(TOKEN_ALIAS));
    try {
      await asset.remove(query);
    } catch {
      // Absent is the desired end state anyway.
    }
  }

  /**
   * The launch token is the only thing that can mint DSH's browser cookie, so the
   * WebView container needs it. It dies with the host process, which is why it is
   * stored separately from the long-lived device token.
   */  async saveStartupToken(token: string): Promise<void> {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, PanelStore.toBytes(STARTUP_ALIAS));
    attributes.set(asset.Tag.SECRET, PanelStore.toBytes(token));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attributes);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === 24000003) {
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, PanelStore.toBytes(STARTUP_ALIAS));
        const update: asset.AssetMap = new Map();
        update.set(asset.Tag.SECRET, PanelStore.toBytes(token));
        await asset.update(query, update);
        return;
      }
      throw error as Error;
    }
  }

  async loadStartupToken(): Promise<string> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, PanelStore.toBytes(STARTUP_ALIAS));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      return PanelStore.fromBytes(results[0].get(asset.Tag.SECRET) as Uint8Array);
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      if (businessError.code === 24000002) {
        return '';
      }
      throw error as Error;
    }
  }

  /** Cold-start journal: the last picture before the process died (design §7.2.5). */
  async saveJournal(json: string): Promise<void> {
    try {
      const store: preferences.Preferences = await this.prefs();
      await store.put(JOURNAL_KEY, json);
      await store.flush();
    } catch {
      // A failed journal write must never disturb the live path.
    }
  }

  async loadJournal(): Promise<string> {
    try {
      const store: preferences.Preferences = await this.prefs();
      return await store.get(JOURNAL_KEY, '') as string;
    } catch {
      return '';
    }
  }

  private static toBytes(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }

  private static fromBytes(bytes: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }
}
