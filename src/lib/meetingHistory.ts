import { supabase } from './supabase';

export type MeetingHistoryEntry = {
  id: number;
  actor_id: string;
  actor_name: string;
  occurred_at: string;
  category: 'planning' | 'publication' | 'live';
  event_type: string;
  summary: string;
  details: Record<string, unknown>;
  published_version: number | null;
};

export async function getMeetingHistory(workspaceId: string, meetingId: string, beforeId: number | null = null, pageSize = 30) {
  if (!supabase) throw new Error('La conexión con UNARA no está disponible.');
  const { data, error } = await supabase.rpc('get_workspace_meeting_history', {
    target_workspace: workspaceId,
    target_meeting: meetingId,
    before_id: beforeId,
    page_size: pageSize,
  });
  if (error) throw error;
  return (data || []) as MeetingHistoryEntry[];
}
