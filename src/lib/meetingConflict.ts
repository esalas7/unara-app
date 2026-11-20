export type MeetingPlanShape = Record<string, unknown> & { id: string };

/** Three-way field merge. Returns null when both sides changed the same field differently. */
export function mergeMeetingDraftFields<T extends MeetingPlanShape>(base: T, local: T, remote: T): T | null {
  const merged: Record<string, unknown> = { ...remote };
  for (const key of new Set([...Object.keys(base), ...Object.keys(local), ...Object.keys(remote)])) {
    if (['id', 'status', 'published_version', 'published_at'].includes(key)) continue;
    const oldValue = base[key] ?? null;
    const localValue = local[key] ?? null;
    const remoteValue = remote[key] ?? null;
    const localChanged = JSON.stringify(localValue) !== JSON.stringify(oldValue);
    const remoteChanged = JSON.stringify(remoteValue) !== JSON.stringify(oldValue);
    if (localChanged && remoteChanged && JSON.stringify(localValue) !== JSON.stringify(remoteValue)) return null;
    if (localChanged) merged[key] = local[key];
  }
  return merged as T;
}
