import { supabase } from './supabase';

export type MeetingLiveState = {
  workspace_id: string;
  meeting_id: string;
  current_section_id: string | null;
  general_elapsed_seconds: number;
  general_started_at: string | null;
  general_is_running: boolean;
  updated_at: string;
  updated_by: string | null;
};

export type MeetingSectionTimer = {
  workspace_id: string;
  meeting_id: string;
  section_id: string;
  elapsed_seconds: number;
  started_at: string | null;
  is_running: boolean;
  updated_at: string;
  updated_by: string | null;
};

export type MeetingLiveSong = {
  id: string;
  workspace_id: string;
  meeting_id: string;
  section_id: string;
  song_id: string;
  after_item_id: string | null;
  created_at: string;
  created_by: string | null;
};

export type MeetingLiveAction = 'general_start' | 'general_pause' | 'general_reset' |
  'section_start' | 'section_pause' | 'section_reset' | 'add_song';

export type MeetingLaunchState = {
  workspace_id: string;
  meeting_id: string;
  host_user_id: string | null;
  scheduled_at: string | null;
  time_zone: string;
  status: 'disabled' | 'scheduled' | 'cancelled' | 'started' | 'completed';
  started_event_id: string | null;
  started_at: string | null;
  server_now: string;
  rescheduled_from: string | null;
};

export type MeetingLaunchAction = 'start_now' | 'cancel' | 'postpone';

function api() {
  if (!supabase) throw new Error('La conexión con UNARA no está disponible.');
  return supabase;
}

export async function getMeetingLiveData(workspaceId: string, meetingId: string) {
  const client = api();
  const [stateResult, timerResult, songResult] = await Promise.all([
    client.from('workspace_meeting_live_state').select('*').eq('workspace_id', workspaceId).eq('meeting_id', meetingId).maybeSingle(),
    client.from('workspace_meeting_section_timers').select('*').eq('workspace_id', workspaceId).eq('meeting_id', meetingId),
    client.from('workspace_meeting_live_songs').select('*').eq('workspace_id', workspaceId).eq('meeting_id', meetingId).order('created_at').order('id'),
  ]);
  if (stateResult.error) throw stateResult.error;
  if (timerResult.error) throw timerResult.error;
  if (songResult.error) throw songResult.error;
  return {
    state: (stateResult.data || null) as MeetingLiveState | null,
    timers: (timerResult.data || []) as MeetingSectionTimer[],
    songs: (songResult.data || []) as MeetingLiveSong[],
  };
}

export async function getMeetingLaunchState(workspaceId: string, meetingId: string) {
  const { data, error } = await api().rpc('get_workspace_meeting_launch_state', {
    target_workspace: workspaceId,
    target_meeting: meetingId,
  });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  return (row || null) as MeetingLaunchState | null;
}

export async function runMeetingLaunchAction(input: {
  workspaceId: string;
  meetingId: string;
  action: MeetingLaunchAction;
  postponeDate?: string;
  postponeTime?: string;
}) {
  const { data, error } = await api().rpc('manage_workspace_meeting_launch_action', {
    target_workspace: input.workspaceId,
    target_meeting: input.meetingId,
    launch_action: input.action,
    new_local_date: input.postponeDate || null,
    new_local_time: input.postponeTime || null,
  });
  if (error) throw error;
  return data as string | null;
}

export async function runMeetingHostLiveAction(input: {
  workspaceId: string;
  meetingId: string;
  action: Exclude<MeetingLiveAction, 'add_song'>;
  sectionId?: string;
}) {
  const { error } = await api().rpc('manage_workspace_meeting_host_live_action', {
    target_workspace: input.workspaceId,
    target_meeting: input.meetingId,
    live_action: input.action,
    target_section: input.sectionId || null,
  });
  if (error) throw error;
}

export async function runMeetingLiveAction(input: {
  workspaceId: string;
  meetingId: string;
  action: MeetingLiveAction;
  sectionId?: string;
  songId?: string;
  afterItemId?: string | null;
}) {
  const { error } = await api().rpc('manage_workspace_meeting_live_action', {
    target_workspace: input.workspaceId,
    target_meeting: input.meetingId,
    live_action: input.action,
    target_section: input.sectionId || null,
    source_song: input.songId || null,
    after_item: input.afterItemId || null,
  });
  if (error) throw error;
}

export function liveElapsedSeconds(elapsedSeconds: number, startedAt: string | null, isRunning: boolean, now = Date.now()) {
  if (!isRunning || !startedAt) return Math.max(0, elapsedSeconds || 0);
  return Math.max(0, (elapsedSeconds || 0) + Math.floor((now - new Date(startedAt).getTime()) / 1000));
}

/** Remaining seconds derived from the server-backed elapsed timer and section estimate. */
export function liveSectionRemainingSeconds(estimatedMinutes: number, elapsedSeconds: number) {
  return Math.max(0, Math.floor(estimatedMinutes || 0)) * 60 - Math.max(0, Math.floor(elapsedSeconds || 0));
}

/** Format a signed timer value without changing the stored elapsed-time model. */
export function formatLiveSectionTime(seconds: number, overrun = false) {
  const value = Math.abs(Math.trunc(seconds));
  const hours = Math.floor(value / 3600);
  const minutes = Math.floor((value % 3600) / 60);
  const remainder = value % 60;
  const time = hours
    ? `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(remainder).padStart(2, '0')}`
    : `${String(minutes).padStart(2, '0')}:${String(remainder).padStart(2, '0')}`;
  if (seconds < 0) return `−${time}`;
  if (overrun && seconds > 0) return `+${time}`;
  return time;
}
