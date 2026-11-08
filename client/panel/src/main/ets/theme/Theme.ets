/**
 * Design tokens for the panel UI.
 *
 * Kept in one place so the pages read like a product rather than a demo: a single
 * brand colour, a calm neutral surface stack, and a four-step type scale.
 */
export class Theme {
  static readonly brand: string = '#0A59F7';
  static readonly brandSoft: string = '#E8EFFF';

  static readonly bg: string = '#F2F3F5';
  static readonly card: string = '#FFFFFF';
  static readonly cardAlt: string = '#F7F8FA';

  static readonly textPrimary: string = '#182431';
  static readonly textSecondary: string = '#6B7480';
  static readonly textTertiary: string = '#9AA3AE';

  static readonly success: string = '#1F9D55';
  static readonly successSoft: string = '#E7F6EC';
  static readonly warning: string = '#B9790B';
  static readonly warningSoft: string = '#FFF6E5';
  static readonly danger: string = '#D93A2B';
  static readonly dangerSoft: string = '#FEECEA';

  static readonly divider: string = '#E7E9EC';
  static readonly border: string = '#E3E7EC';

  static readonly heroFrom: string = '#3D6BFF';
  static readonly heroTo: string = '#0A46D6';

  static readonly radiusCard: number = 16;
  static readonly radiusPill: number = 20;
  static readonly gap: number = 12;
  static readonly pagePadding: number = 16;
}
