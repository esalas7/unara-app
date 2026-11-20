import { supabase } from './supabase';

export type PublicProfile = { id: string; full_name: string; role: string; instruments: string; avatar_path: string | null; avatar_url?: string | null; is_admin?: boolean; workspace_role?: string; team_category?: string; team_functions?: string[]; other_function?: string; membership_status?: 'active'|'pending' };
export type WorkspaceDetails = { id: string; name: string; invite_code?: string; created_by?: string };
export type RecordRow<T> = { id: string; data: T };

function client() {
  if (!supabase) throw new Error('La conexión segura de UNARA aún no está configurada.');
  return supabase;
}

export async function getMyWorkspace(userId: string): Promise<{workspace_id:string;membership_status:'active'|'pending'} | null> {
  const { data, error } = await client().from('workspace_members').select('workspace_id,membership_status').eq('user_id', userId).limit(1).maybeSingle();
  if (error) throw error;
  return data ? data as {workspace_id:string;membership_status:'active'|'pending'} : null;
}

export async function getProfile(userId: string) {
  const { data, error } = await client().from('profiles').select('id,full_name,role,instruments,avatar_path').eq('id', userId).single();
  if (error) throw error;
  return { ...data, avatar_url: await getAvatarUrl(data.avatar_path) } as PublicProfile;
}

export async function getMyBirthday(userId: string) {
  const { data, error } = await client().from('profile_birthdays').select('date_of_birth').eq('user_id', userId).maybeSingle();
  if (error) throw error;
  return data?.date_of_birth || '';
}

export async function getAvatarUrl(path: string | null | undefined) {
  if (!path) return null;
  const { data, error } = await client().storage.from('profile-photos').createSignedUrl(path, 60 * 60 * 12);
  if (error) return null;
  return data.signedUrl;
}

export async function saveMyProfile(input: { userId: string; fullName: string; birthday: string; avatarPath: string | null }) {
  const api = client();
  const { error: profileError } = await api.from('profiles').update({
    full_name: input.fullName.trim(), avatar_path: input.avatarPath,
  }).eq('id', input.userId);
  if (profileError) throw profileError;
  const { error: birthdayError } = await api.from('profile_birthdays').upsert(
    { user_id: input.userId, date_of_birth: input.birthday }, { onConflict: 'user_id' },
  );
  if (birthdayError) throw birthdayError;
  return getProfile(input.userId);
}

export async function uploadProfilePhoto(userId: string, file: File) {
  if (!file.type.startsWith('image/')) throw new Error('Elige una imagen JPG, PNG o WEBP.');
  if (file.size > 5 * 1024 * 1024) throw new Error('La foto debe pesar menos de 5 MB.');
  const extension = file.name.split('.').pop()?.toLowerCase().replace(/[^a-z0-9]/g, '') || 'jpg';
  const path = `${userId}/${crypto.randomUUID()}.${extension}`;
  const { error } = await client().storage.from('profile-photos').upload(path, file, { cacheControl: '3600', upsert: false });
  if (error) throw error;
  return path;
}

export async function removeProfilePhoto(path: string) {
  const { error } = await client().storage.from('profile-photos').remove([path]);
  if (error) throw error;
}

export async function createWorkspace(name: string) {
  const { data, error } = await client().rpc('create_workspace', { workspace_name: name });
  if (error) throw error;
  return (Array.isArray(data) ? data[0] : data) as WorkspaceDetails;
}

export async function joinWorkspace(code: string) {
  const normalizedCode = code.trim().replace(/[\s-]/g, '').toUpperCase();
  const { data, error } = await client().rpc('join_workspace', { code: normalizedCode });
  if (error) throw error;
  return (Array.isArray(data) ? data[0] : data) as { id: string; name: string };
}

export async function getWorkspaceDetails(workspaceId: string) {
  const { data, error } = await client().from('workspaces').select('id,name,created_by').eq('id', workspaceId).single();
  if (error) throw error;
  return data as WorkspaceDetails;
}

export async function getWorkspaceMembers(workspaceId: string): Promise<PublicProfile[]> {
  const { data, error } = await client()
    .from('workspace_members')
    .select('is_admin,workspace_role,team_category,team_functions,other_function,membership_status,profile:profiles!workspace_members_user_id_fkey(id,full_name,role,instruments,avatar_path)')
    .eq('workspace_id', workspaceId);
  if (error) throw error;
  const profiles = await Promise.all((data || []).map(async (row: any) => {
    const profile = row.profile as PublicProfile | null;
    return profile ? { ...profile, is_admin: row.is_admin, workspace_role: row.workspace_role, team_category: row.team_category, team_functions: row.team_functions || [], other_function: row.other_function || '', membership_status: row.membership_status, avatar_url: await getAvatarUrl(profile.avatar_path) } : null;
  }));
  return profiles.filter(profile => profile !== null);
}

export async function getWorkspaceInviteCode(workspaceId: string) {
  const { data, error } = await client().rpc('get_workspace_invite_code', { target_workspace: workspaceId });
  if (error) throw error;
  return data as string;
}

export async function manageWorkspaceMember(input: { workspaceId: string; userId: string; teamCategory: string; teamFunctions: string[]; otherFunction: string; workspaceRole: string }) {
  const { error } = await client().rpc('manage_workspace_member', {
    target_workspace: input.workspaceId, target_user: input.userId, new_team_category: input.teamCategory,
    new_team_functions: input.teamFunctions, new_other_function: input.otherFunction, new_workspace_role: input.workspaceRole,
  });
  if (error) throw error;
}

export async function removeWorkspaceMember(workspaceId: string, userId: string) {
  const { error } = await client().rpc('remove_workspace_member', { target_workspace: workspaceId, target_user: userId });
  if (error) throw error;
}

export async function reviewWorkspaceMember(workspaceId: string, userId: string, approve: boolean) {
  const { error } = await client().rpc('review_workspace_member', { target_workspace: workspaceId, target_user: userId, approve });
  if (error) throw error;
}

export async function transferWorkspaceOwnership(workspaceId: string, newOwnerId: string) {
  const { error } = await client().rpc('transfer_workspace_ownership', { target_workspace: workspaceId, new_owner: newOwnerId });
  if (error) throw error;
}

export async function setWorkspaceName(workspaceId: string, name: string) {
  const { error } = await client().from('workspaces').update({ name: name.trim() }).eq('id', workspaceId);
  if (error) throw error;
}

export async function deleteWorkspace(workspaceId: string) {
  const { error } = await client().from('workspaces').delete().eq('id', workspaceId);
  if (error) throw error;
}

export type MeetingAssignment = { workspace_id: string; meeting_id: string; user_id: string; function_name: string; instrument: string };

export async function getMeetingAssignments(workspaceId: string, meetingId: string): Promise<MeetingAssignment[]> {
  const { data, error } = await client().from('workspace_meeting_assignments').select('*').eq('workspace_id', workspaceId).eq('meeting_id', meetingId);
  if (error) throw error;
  return (data || []) as MeetingAssignment[];
}

export async function setMeetingAssignment(input: MeetingAssignment) {
  const api = client();
  const { error: removeError } = await api.from('workspace_meeting_assignments').delete().eq('workspace_id', input.workspace_id).eq('meeting_id', input.meeting_id).eq('user_id', input.user_id);
  if (removeError) throw removeError;
  if (!input.function_name) return;
  const { error } = await api.from('workspace_meeting_assignments').insert(input);
  if (error) throw error;
}

export async function saveWorkspaceMeeting<T extends { id: string }>(
  workspaceId: string,
  meeting: T,
  assignments: Pick<MeetingAssignment, 'user_id' | 'function_name'>[] | null,
) {
  const args: Record<string, unknown> = {
    target_workspace: workspaceId,
    meeting_data: meeting,
  };
  if (assignments !== null) args.selected_assignments = assignments;
  const { error } = await client().rpc('save_workspace_meeting', args);
  if (error) throw error;
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
    const { error } = await api.rpc('seed_workspace_meetings', {
      target_workspace: workspaceId,
      meeting_rows: meetings,
    });
    if (error) throw error;
  }
}
