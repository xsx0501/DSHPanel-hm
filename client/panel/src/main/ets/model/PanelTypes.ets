/**
 * Wire types for the DSH panel bridge (`dsh-panel-bridge` host plugin).
 *
 * Everything here mirrors docs/design.md §8.3 (B column) and the实测 results in
 * §3.6.7: pairing uses the launch token, everything else uses the device token.
 */

export interface ImportIntent {
  baseUrl: string;
  startupToken: string;
}

/** One DSH deployment the phone knows about (docs/design.md §6.3). */
export interface NodeInfo {
  id: string;
  name: string;
  baseUrl: string;
  lastUsedAt: number;
}

export interface DeviceInfo {
  id: string;
  name: string;
  createdAt: number;
  lastSeenAt: number | null;
  revokedAt: number | null;
  scopes: string[];
}

export interface PairResponse {
  ok: boolean;
  device?: DeviceInfo;
  deviceToken?: string;
  code?: string;
}

export interface SessionStats {
  turns: number;
  steps: number;
  llmMs?: number;
  toolMs?: number;
  decodeTokens?: number;
  decodeMs?: number;
}

export interface SessionSummary {
  sessionId: string;
  title: string | null;
  cwd: string | null;
  running: boolean;
  updatedAt: number | null;
  sessionStats: SessionStats | null;
  pendingApprovals: number;
}

export interface BootstrapResponse {
  ok: boolean;
  schemaVersion?: string;
  host?: HostInfo;
  sessions?: SessionSummary[];
  pendingApprovals?: PendingApproval[];
  capabilities?: PanelCapabilities;
  code?: string;
}

export interface HostInfo {
  home: string;
  dshVersion: string | null;
}

export interface PanelCapabilities {
  confirm: boolean;
  abort: boolean;
  stream: string;
  pairing: boolean;
  rememberRule: boolean;
}

export interface PendingApproval {
  approvalId: string;
  sessionId: string;
  toolName: string;
  riskLevel: string;
  preview: string;
  requestedAt: number;
  timeoutSeconds: number;
}

/** One flattened host record, as produced by the plugin's `flattenRecord`. */
export interface PanelEvent {
  seq: number;
  sessionId: string;
  type: string;
  ts: number;
  payload: PanelEventPayload;
}

export interface PanelEventPayload {
  seq?: number;
  time?: number;
  turn?: number;
  step?: number;
  ok?: boolean;
  outcome?: string;
  callId?: string;
  tool?: string;
  summary?: string;
  preview?: string;
  tokens?: number;
  title?: string;
  approvalId?: string;
  toolName?: string;
  riskLevel?: string;
  reason?: string;
}

export interface ConfirmResponse {
  ok: boolean;
  approvalId?: string;
  code?: string;
}

/** Request bodies (declared so ArkTS object literals stay typed). */
export interface PairRequest {
  startupToken: string;
  deviceName: string;
}

export interface ConfirmRequest {
  approvalId: string;
  decision: string;
  rememberRule: boolean;
}

export interface AbortRequest {
  sessionId: string;
}

/** One session's newest progress, used by the background poller. */
export interface SnapshotProgress {
  turn: number | null;
  step: number | null;
  type: string;
  at: number;
}

export interface SnapshotLatest {
  sessionId: string;
  type: string;
  text: string;
  at: number;
}

export interface SnapshotResponse {
  ok: boolean;
  progress: Record<string, SnapshotProgress>;
  latest: SnapshotLatest | null;
  pendingApprovals: PendingApproval[];
  seq: number | null;
}