import type { MeetingLiveSong } from './meetingLive';

export const meetingSectionOptions = [
  { type: 'alabanza', label: 'Alabanza' },
  { type: 'adoracion', label: 'Adoración' },
  { type: 'anuncios', label: 'Anuncios' },
  { type: 'predicacion', label: 'Predicación' },
  { type: 'ministracion', label: 'Ministración' },
] as const;

export type MeetingSectionType = typeof meetingSectionOptions[number]['type'];
export type MeetingAgendaItem =
  | { id: string; type: 'song'; songId: string }
  | { id: string; type: 'activity'; text: string };
export type MeetingSection = {
  id: string;
  type: MeetingSectionType | 'legacy';
  estimatedMinutes: number;
  items: MeetingAgendaItem[];
};
export type MeetingAgenda = { version: 1; sections: MeetingSection[] };
export type MeetingWithAgenda = {
  id: string;
  songs: string[];
  agenda?: MeetingAgenda;
};

const legacySectionId = 'legacy-repertoire';

export function sectionLabel(type: MeetingSection['type']) {
  if (type === 'legacy') return 'Repertorio anterior';
  return meetingSectionOptions.find(option => option.type === type)?.label || type;
}

export function getMeetingSections(meeting: MeetingWithAgenda): MeetingSection[] {
  if (meeting.agenda && Array.isArray(meeting.agenda.sections)) return meeting.agenda.sections;
  if (!meeting.songs.length) return [];
  return [{
    id: legacySectionId,
    type: 'legacy',
    estimatedMinutes: 0,
    items: meeting.songs.map((songId, index) => ({
      id: `legacy-song-${index}-${songId}`,
      type: 'song' as const,
      songId,
    })),
  }];
}

export function getAgendaSongIds(sections: MeetingSection[]) {
  return sections.flatMap(section => section.items.flatMap(item => item.type === 'song' ? [item.songId] : []));
}

export function getMeetingSongItems(meeting: MeetingWithAgenda) {
  return getMeetingSections(meeting).flatMap(section => section.items.flatMap(item => item.type === 'song'
    ? [{ id: item.id, songId: item.songId, sectionId: section.id, sectionType: section.type }]
    : []));
}

export function mergeMeetingLiveSongs(items: MeetingAgendaItem[], extras: MeetingLiveSong[]): (MeetingAgendaItem & { isLive?: boolean })[] {
  const children = new Map<string, MeetingLiveSong[]>();
  for (const extra of extras) {
    const anchor = extra.after_item_id || '';
    children.set(anchor, [...(children.get(anchor) || []), extra]);
  }
  for (const group of children.values()) group.sort((a,b)=>a.created_at.localeCompare(b.created_at)||a.id.localeCompare(b.id));
  const output: (MeetingAgendaItem & { isLive?: boolean })[] = [];
  const visited = new Set<string>();
  const appendChildren = (anchor: string) => {
    for (const extra of children.get(anchor) || []) {
      if (visited.has(extra.id)) continue;
      visited.add(extra.id);
      output.push({ id: extra.id, type: 'song', songId: extra.song_id, isLive: true });
      appendChildren(extra.id);
    }
  };
  appendChildren('');
  for (const item of items) {
    output.push(item);
    appendChildren(item.id);
  }
  for (const extra of extras) {
    if (visited.has(extra.id)) continue;
    visited.add(extra.id);
    output.push({ id: extra.id, type: 'song', songId: extra.song_id, isLive: true });
    appendChildren(extra.id);
  }
  return output;
}

export function getMeetingSongItemsWithLive(meeting: MeetingWithAgenda, extras: MeetingLiveSong[]) {
  return getMeetingSections(meeting).flatMap(section => mergeMeetingLiveSongs(
    section.items,
    extras.filter(song => song.section_id === section.id),
  ).flatMap(item => item.type === 'song'
    ? [{ id: item.id, songId: item.songId, sectionId: section.id, sectionType: section.type, isLive: !!item.isLive }]
    : []));
}

export function getMeetingSongIds(meeting: MeetingWithAgenda) {
  return getMeetingSongItems(meeting).map(item => item.songId);
}

export function getMeetingDuration(sections: MeetingSection[]) {
  return sections.reduce((total, section) => {
    const minutes = Number(section.estimatedMinutes);
    return total + (Number.isFinite(minutes) ? Math.max(0, Math.floor(minutes)) : 0);
  }, 0);
}

export function saveMeetingSections<T extends MeetingWithAgenda>(meeting: T, sections: MeetingSection[]): T {
  const cleaned = sections
    .filter(section => section.type !== 'legacy' || section.items.length > 0)
    .map(section => ({ ...section, items: [...section.items] }));
  return { ...meeting, agenda: { version: 1, sections: cleaned }, songs: getAgendaSongIds(cleaned) };
}

export function reorderMeetingSection(sections: MeetingSection[], sectionId: string, direction: -1 | 1) {
  const from = sections.findIndex(section => section.id === sectionId);
  const to = from + direction;
  if (from < 0 || to < 0 || to >= sections.length) return sections;
  const next = [...sections];
  [next[from], next[to]] = [next[to], next[from]];
  return next;
}

export function reorderMeetingItem(sections: MeetingSection[], sectionId: string, itemId: string, direction: -1 | 1) {
  return sections.map(section => {
    if (section.id !== sectionId) return section;
    const from = section.items.findIndex(item => item.id === itemId);
    const to = from + direction;
    if (from < 0 || to < 0 || to >= section.items.length) return section;
    const items = [...section.items];
    [items[from], items[to]] = [items[to], items[from]];
    return { ...section, items };
  });
}

export function moveMeetingItem(sections: MeetingSection[], fromSectionId: string, itemId: string, toSectionId: string) {
  if (fromSectionId === toSectionId) return sections;
  const source = sections.find(section => section.id === fromSectionId);
  const destination = sections.find(section => section.id === toSectionId);
  const item = source?.items.find(entry => entry.id === itemId);
  if (!source || !destination || !item) return sections;
  return sections
    .map(section => {
      if (section.id === fromSectionId) return { ...section, items: section.items.filter(entry => entry.id !== itemId) };
      if (section.id === toSectionId) return { ...section, items: [...section.items, item] };
      return section;
    })
    .filter(section => section.type !== 'legacy' || section.items.length > 0);
}

export function removeMeetingItem(sections: MeetingSection[], sectionId: string, itemId: string) {
  return sections
    .map(section => section.id === sectionId
      ? { ...section, items: section.items.filter(item => item.id !== itemId) }
      : section)
    .filter(section => section.type !== 'legacy' || section.items.length > 0);
}

export function removeSongFromMeeting<T extends MeetingWithAgenda>(meeting: T, songId: string): T {
  if (!meeting.agenda) return { ...meeting, songs: meeting.songs.filter(id => id !== songId) };
  const sections = meeting.agenda.sections.map(section => ({
    ...section,
    items: section.items.filter(item => item.type !== 'song' || item.songId !== songId),
  }));
  return saveMeetingSections(meeting, sections);
}
