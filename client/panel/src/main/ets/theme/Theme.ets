/**
 * Design tokens for the panel UI.
 *
 * Every colour is a *resource* (`app.color.*`) with a `dark` counterpart, so the
 * whole app follows the system colour mode without any page-level branching: the
 * resources resolve to the active qualifier and ArkUI re-renders on a mode change.
 */
export class Theme {
  static readonly brand: ResourceColor = $r('app.color.brand');
  static readonly brandSoft: ResourceColor = $r('app.color.brand_soft');

  static readonly bg: ResourceColor = $r('app.color.bg');
  static readonly bgTop: ResourceColor = $r('app.color.bg_top');
  static readonly bgMid: ResourceColor = $r('app.color.bg_mid');
  static readonly bgBottom: ResourceColor = $r('app.color.bg_bot');
  static readonly card: ResourceColor = $r('app.color.card');
  static readonly cardAlt: ResourceColor = $r('app.color.card_alt');
  static readonly glass: ResourceColor = $r('app.color.glass');
  static readonly glassStrong: ResourceColor = $r('app.color.glass_strong');
  static readonly scrim: ResourceColor = $r('app.color.scrim');
  static readonly handleBg: ResourceColor = $r('app.color.handle_bg');

  static readonly textPrimary: ResourceColor = $r('app.color.text_primary');
  static readonly textSecondary: ResourceColor = $r('app.color.text_secondary');
  static readonly textTertiary: ResourceColor = $r('app.color.text_tertiary');
  static readonly textOnBrand: ResourceColor = $r('app.color.text_on_brand');
  static readonly textOnBrandDim: ResourceColor = $r('app.color.text_on_brand_dim');

  static readonly success: ResourceColor = $r('app.color.success');
  static readonly successSoft: ResourceColor = $r('app.color.success_soft');
  static readonly warning: ResourceColor = $r('app.color.warning');
  static readonly warningSoft: ResourceColor = $r('app.color.warning_soft');
  static readonly danger: ResourceColor = $r('app.color.danger');
  static readonly dangerSoft: ResourceColor = $r('app.color.danger_soft');

  static readonly divider: ResourceColor = $r('app.color.divider');
  static readonly border: ResourceColor = $r('app.color.border');

  static readonly heroFrom: ResourceColor = $r('app.color.hero_from');
  static readonly heroTo: ResourceColor = $r('app.color.hero_to');
  static readonly pillOnBrand: ResourceColor = $r('app.color.pill_on_brand');
  static readonly iconGhost: ResourceColor = $r('app.color.icon_ghost');

  static readonly radiusCard: number = 16;
  static readonly radiusPill: number = 20;
  static readonly gap: number = 12;
  static readonly pagePadding: number = 16;
}
