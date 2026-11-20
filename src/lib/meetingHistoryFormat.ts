type SongLike = { id: string; title: string };
type MemberLike = { id: string; name: string; team_functions: string[]; other_function?: string };
type AgendaItem = { id?: string; type?: string; songId?: string; text?: string };
type Section = { id?: string; type?: string; estimatedMinutes?: number; items?: AgendaItem[] };

const labels: Record<string, string> = {
  title: 'Nombre de la reunión', date: 'Fecha', time: 'Horario', place: 'Lugar',
  comments: 'Comentarios e indicaciones',
};

function display(value: unknown) {
  if (value === null || value === undefined || value === '') return 'Sin especificar';
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return String(value);
  return 'Información actualizada';
}

function sectionName(section: Section) {
  const names: Record<string, string> = { alabanza: 'Alabanza', adoracion: 'Adoración', anuncios: 'Anuncios', predicacion: 'Predicación', ministracion: 'Ministración', legacy: 'Repertorio anterior' };
  return names[section.type || ''] || 'Sección';
}

function sectionList(value: unknown): Section[] {
  if (!value || typeof value !== 'object') return [];
  const sections = (value as { sections?: unknown }).sections;
  return Array.isArray(sections) ? sections as Section[] : [];
}

function itemLabel(item: AgendaItem, songs: SongLike[]) {
  if (item.type === 'song') return songs.find(song => song.id === item.songId)?.title || 'una canción del repertorio';
  return item.type === 'activity' ? `la indicación «${display(item.text)}»` : 'un elemento';
}

export function describePlanningChanges(changes: Record<string, { old: unknown; new: unknown }>, songs: SongLike[], members: MemberLike[]) {
  const lines: string[] = [];
  for (const [field, change] of Object.entries(changes || {})) {
    if (labels[field]) {
      if (field === 'comments') lines.push('Se modificaron los comentarios e indicaciones.');
      else lines.push(`Se modificó ${labels[field].toLowerCase()}: ${display(change.old)} → ${display(change.new)}.`);
      continue;
    }
    if (field === 'songs') {
      if (changes.agenda) continue;
      const before = Array.isArray(change.old) ? change.old as string[] : [];
      const after = Array.isArray(change.new) ? change.new as string[] : [];
      const counts = (ids: string[]) => { const result = new Map<string, number>(); for (const id of ids) result.set(id, (result.get(id) || 0) + 1); return result; };
      const oldCounts = counts(before); const newCounts = counts(after);
      for (const id of new Set([...oldCounts.keys(), ...newCounts.keys()])) {
        const difference = (newCounts.get(id) || 0) - (oldCounts.get(id) || 0);
        const title = songs.find(song => song.id === id)?.title || 'una canción del repertorio anterior';
        if (difference > 0) lines.push(`Se agregó ${title} al repertorio anterior${difference > 1 ? ` (${difference} veces)` : ''}.`);
        if (difference < 0) lines.push(`Se quitó ${title} del repertorio anterior${difference < -1 ? ` (${Math.abs(difference)} veces)` : ''}.`);
      }
      if (!before.every((id, index) => after[index] === id) && before.length === after.length && [...oldCounts].every(([id, count]) => count === newCounts.get(id))) lines.push('Se cambió el orden del repertorio anterior.');
      continue;
    }
    if (field === 'agenda') {
      lines.push(...describeAgenda(change.old, change.new, songs));
      continue;
    }
    if (field === 'assignments') {
      lines.push(...describeAssignments(change.old, change.new, members));
    }
  }
  return [...new Set(lines)];
}

function describeAgenda(oldValue: unknown, newValue: unknown, songs: SongLike[]) {
  const before = sectionList(oldValue); const after = sectionList(newValue); const lines: string[] = [];
  const oldById = new Map(before.map((section, index) => [section.id || `old-${index}`, { section, index }]));
  const newById = new Map(after.map((section, index) => [section.id || `new-${index}`, { section, index }]));
  for (const [id, { section }] of oldById) if (!newById.has(id)) lines.push(`Se eliminó la sección ${sectionName(section)}.`);
  for (const [id, { section }] of newById) if (!oldById.has(id)) lines.push(`Se agregó la sección ${sectionName(section)}.`);
  const oldOrder = before.map((section, index) => section.id || `old-${index}`).filter(id => newById.has(id)); const newOrder = after.map((section, index) => section.id || `new-${index}`).filter(id => oldById.has(id));
  if (oldOrder.length === newOrder.length && oldOrder.some((id, index) => id !== newOrder[index])) lines.push('Se cambió el orden de las secciones.');
  for (const [id, oldEntry] of oldById) {
    const next = newById.get(id); if (!next) continue;
    const oldSection = oldEntry.section; const newSection = next.section; const name = sectionName(newSection);
    if (Number(oldSection.estimatedMinutes || 0) !== Number(newSection.estimatedMinutes || 0)) lines.push(`Se modificó el tiempo estimado de ${name}: ${Number(oldSection.estimatedMinutes || 0)} → ${Number(newSection.estimatedMinutes || 0)} minutos.`);
    const oldItems = oldSection.items || []; const newItems = newSection.items || [];
    const oldItemsById = new Map(oldItems.map((item, index) => [item.id || `old-${index}`, { item, index }]));
    const newItemsById = new Map(newItems.map((item, index) => [item.id || `new-${index}`, { item, index }]));
    for (const [itemId, { item }] of oldItemsById) if (!newItemsById.has(itemId)) {
      const moved = !!item.id && after.some(section => (section.items || []).some(candidate => candidate.id === item.id));
      if (!moved) lines.push(item.type === 'song' ? `Se quitó ${itemLabel(item, songs)} de ${name}.` : `Se quitó ${itemLabel(item, songs)} de ${name}.`);
    }
    for (const [itemId, { item }] of newItemsById) if (!oldItemsById.has(itemId)) {
      const moved = !!item.id && before.some(section => (section.items || []).some(candidate => candidate.id === item.id));
      if (!moved) lines.push(item.type === 'song' ? `Se agregó ${itemLabel(item, songs)} a ${name}.` : `Se agregó ${itemLabel(item, songs)} a ${name}.`);
      else lines.push(`Se trasladó ${itemLabel(item, songs)} a ${name}.`);
    }
    for (const [itemId, { item: oldItem }] of oldItemsById) {
      const newer = newItemsById.get(itemId)?.item;
      if (newer?.type === 'activity' && oldItem.type === 'activity' && newer.text !== oldItem.text) lines.push(`Se modificó una indicación de ${name}: «${display(oldItem.text)}» → «${display(newer.text)}».`);
    }
    const oldItemOrder = oldItems.map((item, index) => item.id || `old-${index}`).filter(id => newItemsById.has(id)); const newItemOrder = newItems.map((item, index) => item.id || `new-${index}`).filter(id => oldItemsById.has(id));
    if (oldItemOrder.length === newItemOrder.length && oldItemOrder.some((itemId, index) => itemId !== newItemOrder[index])) lines.push(`Se cambió el orden de los elementos en ${name}.`);
  }
  return lines;
}

function describeAssignments(oldValue: unknown, newValue: unknown, members: MemberLike[]) {
  const before = Array.isArray(oldValue) ? oldValue as { user_id?: string; function_name?: string }[] : [];
  const after = Array.isArray(newValue) ? newValue as { user_id?: string; function_name?: string }[] : [];
  const key = (item: { user_id?: string; function_name?: string }) => `${item.user_id || ''}|${item.function_name || ''}`;
  const oldSet = new Set(before.map(key)); const newSet = new Set(after.map(key)); const lines: string[] = [];
  const describe = (item: { user_id?: string; function_name?: string }) => {
    const member = members.find(person => person.id === item.user_id);
    return `${member?.name || 'Un integrante'}${item.function_name ? ` (${item.function_name})` : ''}`;
  };
  const previousByMember = new Map<string, typeof before>(); const currentByMember = new Map<string, typeof after>();
  for (const item of before) previousByMember.set(item.user_id || '', [...(previousByMember.get(item.user_id || '') || []), item]);
  for (const item of after) currentByMember.set(item.user_id || '', [...(currentByMember.get(item.user_id || '') || []), item]);
  for (const userId of new Set([...previousByMember.keys(), ...currentByMember.keys()])) {
    const previous = previousByMember.get(userId) || []; const current = currentByMember.get(userId) || [];
    if (previous.length === 1 && current.length === 1 && previous[0].function_name !== current[0].function_name) {
      const memberName = members.find(person => person.id === userId)?.name || 'Un integrante';
      lines.push(`Se modificó la función de ${memberName}: ${previous[0].function_name || 'sin función'} → ${current[0].function_name || 'sin función'}.`);
      continue;
    }
    for (const item of previous) if (!newSet.has(key(item))) lines.push(`Se quitó la asignación de ${describe(item)}.`);
    for (const item of current) if (!oldSet.has(key(item))) lines.push(`Se asignó ${describe(item)} a esta reunión.`);
  }
  return lines;
}
