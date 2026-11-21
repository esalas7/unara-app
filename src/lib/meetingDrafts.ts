import { supabase } from './supabase';

export type MeetingDraftAssignments = { user_id: string; function_name: string }[] | null;
export type MeetingDraftRecord<T = Record<string, unknown>> = {
  workspace_id: string;
  meeting_id: string;
  user_id: string;
  data: T;
  selected_assignments: MeetingDraftAssignments;
  revision: number;
  base_published_version: number;
  updated_at: string;
};
export type MeetingNotification = {
  id: string;
  workspace_id: string;
  meeting_id: string;
  recipient_id: string;
  published_version: number;
  meeting_title: string;
  created_at: string;
  read_at: string | null;
};

export type LocalMeetingDraft<T = Record<string, unknown>> = {
  workspace_id: string;
  meeting_id: string;
  data: T;
  selected_assignments: MeetingDraftAssignments;
  expected_revision: number;
  base_published_version: number;
  saved_at: string;
};

function client() {
  if (!supabase) throw new Error('La conexión con UNARA no está disponible.');
  return supabase;
}

export async function getMeetingDraft<T>(workspaceId: string, meetingId: string) {
  const { data, error } = await client().from('workspace_meeting_drafts').select('*')
    .eq('workspace_id', workspaceId).eq('meeting_id', meetingId).maybeSingle();
  if (error) throw error;
  return (data || null) as MeetingDraftRecord<T> | null;
}

export async function listMeetingDrafts<T>(workspaceId: string) {
  const { data, error } = await client().from('workspace_meeting_drafts').select('*')
    .eq('workspace_id', workspaceId).order('updated_at', { ascending: false });
  if (error) throw error;
  return (data || []) as MeetingDraftRecord<T>[];
}

export async function saveMeetingDraft(input: {
  workspaceId: string;
  meetingId: string;
  meeting: Record<string, unknown>;
  assignments: MeetingDraftAssignments;
  expectedRevision: number;
  basePublishedVersion: number;
}) {
  const { data, error } = await client().rpc('save_workspace_meeting_draft', {
    target_workspace: input.workspaceId,
    target_meeting: input.meetingId,
    meeting_data: input.meeting,
    selected_assignments: input.assignments,
    expected_revision: input.expectedRevision,
    expected_published_version: input.basePublishedVersion,
  });
  if (error) throw error;
  return Number(data);
}

export async function publishMeetingDraft(workspaceId: string, meetingId: string, expectedRevision: number, basePublishedVersion: number) {
  const { data, error } = await client().rpc('publish_workspace_meeting_draft', {
    target_workspace: workspaceId,
    target_meeting: meetingId,
    expected_revision: expectedRevision,
    expected_published_version: basePublishedVersion,
  });
  if (error) throw error;
  return Number(data);
}

export async function discardMeetingDraft(workspaceId: string, meetingId: string) {
  const { error } = await client().rpc('discard_workspace_meeting_draft', {
    target_workspace: workspaceId,
    target_meeting: meetingId,
  });
  if (error) throw error;
}

export async function setMeetingStatus(workspaceId: string, meetingId: string, status: string) {
  const { error } = await client().rpc('set_workspace_meeting_status', {
    target_workspace: workspaceId,
    target_meeting: meetingId,
    new_status: status,
  });
  if (error) throw error;
}

export async function deletePublishedMeeting(workspaceId: string, meetingId: string) {
  const { error } = await client().from('workspace_meetings').delete()
    .eq('workspace_id', workspaceId).eq('id', meetingId);
  if (error) throw error;
}

export async function getMeetingNotifications(workspaceId: string) {
  const { data, error } = await client().from('workspace_meeting_notifications').select('*')
    .eq('workspace_id', workspaceId).order('created_at', { ascending: false }).limit(50);
  if (error) throw error;
  return (data || []) as MeetingNotification[];
}

export async function markMeetingNotificationRead(notificationId: string) {
  const { error } = await client().rpc('mark_workspace_meeting_notification_read', { target_notification: notificationId });
  if (error) throw error;
}

function localDraftKey(workspaceId: string, userId: string, meetingId: string) {
  return `unara.meetingDraft.${workspaceId}.${userId}.${meetingId}`;
}

export function readLocalMeetingDraft<T>(workspaceId: string, userId: string, meetingId: string): LocalMeetingDraft<T> | null {
  try {
    const value = localStorage.getItem(localDraftKey(workspaceId, userId, meetingId));
    return value ? JSON.parse(value) as LocalMeetingDraft<T> : null;
  } catch { return null; }
}

export function listLocalMeetingDrafts<T>(workspaceId: string, userId: string): LocalMeetingDraft<T>[] {
  const prefix = `unara.meetingDraft.${workspaceId}.${userId}.`;
  const drafts: LocalMeetingDraft<T>[] = [];
  try {
    for (let i = 0; i < localStorage.length; i += 1) {
      const key = localStorage.key(i);
      if (!key?.startsWith(prefix)) continue;
      const value = localStorage.getItem(key);
      if (value) drafts.push(JSON.parse(value) as LocalMeetingDraft<T>);
    }
  } catch { return drafts; }
  return drafts.sort((a, b) => b.saved_at.localeCompare(a.saved_at));
}

export function writeLocalMeetingDraft<T>(userId: string, draft: LocalMeetingDraft<T>) {
  try { localStorage.setItem(localDraftKey(draft.workspace_id, userId, draft.meeting_id), JSON.stringify(draft)); }
  catch { /* The in-memory editor remains usable; its status will show server errors separately. */ }
}

export function clearLocalMeetingDraft(workspaceId: string, userId: string, meetingId: string) {
  try { localStorage.removeItem(localDraftKey(workspaceId, userId, meetingId)); } catch { /* Storage may be unavailable. */ }
}

export async function getPublishedMeetings<T>(workspaceId: string) {
  const { data, error } = await client().from('workspace_meetings')
    .select('id,data,published_version,published_at,workspace_meeting_launch_state(finished_at)').eq('workspace_id', workspaceId);
  if (error) throw error;
  return (data || []).map(row => {
    const launch = Array.isArray(row.workspace_meeting_launch_state) ? row.workspace_meeting_launch_state[0] : row.workspace_meeting_launch_state;
    return launch?.finished_at ? {...row, data:{...row.data, finished_at:launch.finished_at}} : row;
  }) as { id: string; data: T; published_version: number; published_at: string }[];
}
