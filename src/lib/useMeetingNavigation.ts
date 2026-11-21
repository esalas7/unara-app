import { useEffect, useRef } from 'react';
import { supabase } from './supabase';

type NavigationEvent = { meeting_id: string; event_key: string; screen: string };

export function useMeetingNavigation(workspace: string, user: string, open: (id: string, screen: string) => void) {
  const handler = useRef(open);
  handler.current = open;
  useEffect(() => {
    const client = supabase;
    if (!client) return;
    const storageKey = ['unara', 'live-events', workspace, user].join('.');
    let seen = new Set<string>();
    try { seen = new Set(JSON.parse(sessionStorage.getItem(storageKey) || '[]')); } catch {}
    let disposed = false;
    let sequence = 0;
    async function refresh() {
      const request = ++sequence;
      const result = await client!.rpc('my_meeting_navigation', { target_workspace: workspace });
      if (disposed || request !== sequence || result.error) return;
      const rows = (result.data || []) as NavigationEvent[];
      const key = (row: NavigationEvent) => JSON.stringify([row.meeting_id, row.event_key]);
      const winner = rows[0];
      const navigate = winner && !seen.has(key(winner));
      for (const row of rows) seen.add(key(row));
      try { sessionStorage.setItem(storageKey, JSON.stringify([...seen].slice(-256))); } catch {}
      if (navigate) handler.current(winner.meeting_id, winner.screen);
    }
    const channel = client.channel('global-meeting-events-' + workspace)
      .on('postgres_changes', {event:'*',schema:'public',table:'workspace_meeting_launch_state',filter:'workspace_id=eq.'+workspace}, refresh)
      .subscribe(status => { if (status === 'SUBSCRIBED') void refresh(); });
    void refresh();
    const timer = window.setInterval(refresh, 5000);
    const onVisible = () => { if (!document.hidden) void refresh(); };
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('online', refresh);
    return () => { disposed = true; clearInterval(timer); document.removeEventListener('visibilitychange', onVisible); window.removeEventListener('online', refresh); void client.removeChannel(channel); };
  }, [workspace,user]);
}
