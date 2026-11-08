import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Card state hand-off between the main page and the float view.
 *
 * Both windows run in the same process but not in the same UIContext, so neither
 * AppStorage nor emitter is a reliable channel once the main window is in the
 * background. Preferences is: the main page writes on every flush, the card reads
 * on appear and polls while it is visible.
 */
const STORE_NAME: string = 'panel_card';

export class CardStateStore {
  static async save(context: common.Context, state: Record<string, string>): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
      for (const key of Object.keys(state)) {
        await store.put(key, state[key]);
      }
      await store.flush();
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] card state save failed: ${businessError.code} ${businessError.message}`);
    }
  }

  static async load(context: common.Context): Promise<Record<string, string>> {
    const result: Record<string, string> = {};
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, STORE_NAME);
      for (const key of ['line', 'status', 'title', 'metrics', 'activity', 'preview', 'approvalId', 'events', 'tokens', 'pending', 'sessionShort']) {
        const value = await store.get(key, '');
        result[key] = typeof value === 'string' ? value : '';
      }
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      console.error(`[panel] card state load failed: ${businessError.code} ${businessError.message}`);
    }
    return result;
  }
}
