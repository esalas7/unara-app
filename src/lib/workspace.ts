import { supabase } from './supabase';

export type PublicProfile = { id: string; full_name: string; role: string; instruments: string };
export type WorkspaceDetails = { id: string; name: string; invite_code: string };
export type RecordRow<T> = { id: string; data: T };

function client() {
  if (!supabase) throw new Error('La conexión segura de UNARA aún no está configurada.');
  return supabase;
}

export async function getMyWorkspace(userId: string): Promise<string | null> {
  const { data, error } = await client().from('workspace_members').select('workspace_id').eq('user_id', userId).limit(1).maybeSingle();
  if (error) throw error;
  return data?.workspace_id ?? null;
}

export async function getProfile(userId: string) {
  const { data, error } = await client().from('profiles').select('id,full_name,role,instruments').eq('id', userId).single();
  if (error) throw error;
  return data as PublicProfile;
}

export async function createWorkspace(name: string) {
  const { data, error } = await client().rpc('create_workspace', { workspace_name: name });
  if (error) throw error;
  return (Array.isArray(data) ? data[0] : data) as WorkspaceDetails;
}

export async function joinWorkspace(code: string) {
  const { data, error } = await client().rpc('join_workspace', { code });
  if (error) throw error;
  return (Array.isArray(data) ? data[0] : data) as { id: string; name: string };
}

export async function getWorkspaceDetails(workspaceId: string) {
  const { data, error } = await client().from('workspaces').select('id,name,invite_code').eq('id', workspaceId).single();
  if (error) throw error;
  return data as WorkspaceDetails;
}

export async function getWorkspaceMembers(workspaceId: string): Promise<PublicProfile[]> {
  const { data, error } = await client()
    .from('workspace_members')
    .select('profile:profiles!workspace_members_user_id_fkey(id,full_name,role,instruments)')
    .eq('workspace_id', workspaceId);
  if (error) throw error;
  return (data || []).map((row: any) => row.profile).filter(Boolean) as PublicProfile[];
}

export async function getWorkspaceRows<T>(table: 'workspace_songs' | 'workspace_meetings', workspaceId: string): Promise<RecordRow<T>[]> {
  const { data, error } = await client().from(table).select('id,data').eq('workspace_id', workspaceId);
  if (error) throw error;
  return (data || []) as RecordRow<T>[];
}

export async function saveWorkspaceRows<T>(
  table: 'workspace_songs' | 'workspace_meetings',
  workspaceId: string,
  before: T[],
  after: T[],
) {
  const api = client();
  const previous = new Map(before.map((item: any) => [item.id, JSON.stringify(item)]));
  const next = new Map(after.map((item: any) => [item.id, JSON.stringify(item)]));
  const changed = after.filter((item: any) => previous.get(item.id) !== JSON.stringify(item));
  if (changed.length) {
    const { error } = await api.from(table).upsert(
      changed.map((item: any) => ({ workspace_id: workspaceId, id: item.id, data: item })),
      { onConflict: 'workspace_id,id' },
    );
    if (error) throw error;
  }
  const removed = [...previous.keys()].filter(id => !next.has(id));
  if (removed.length) {
    const { error } = await api.from(table).delete().eq('workspace_id', workspaceId).in('id', removed);
    if (error) throw error;
  }
}

export async function seedWorkspace(workspaceId: string, songs: unknown[], meetings: unknown[]) {
  const api = client();
  if (songs.length) {
    const { error } = await api.from('workspace_songs').upsert(
      songs.map((song: any) => ({ workspace_id: workspaceId, id: song.id, data: song })),
      { onConflict: 'workspace_id,id' },
    );
    if (error) throw error;
  }
  if (meetings.length) {
    const { error } = await api.from('workspace_meetings').upsert(
      meetings.map((meeting: any) => ({ workspace_id: workspaceId, id: meeting.id, data: meeting })),
      { onConflict: 'workspace_id,id' },
    );
    if (error) throw error;
  }
}
