import { useState } from 'react';
import { ArrowDown, ArrowUp, ChevronRight, Music2, Plus, Save, Trash2 } from 'lucide-react';
import {
  getMeetingDuration,
  getMeetingSections,
  MeetingAgendaItem,
  MeetingSection,
  MeetingWithAgenda,
  meetingSectionOptions,
  moveMeetingItem,
  removeMeetingItem,
  reorderMeetingItem,
  reorderMeetingSection,
  saveMeetingSections,
  sectionLabel,
} from './lib/meetingAgenda';

type Song = { id: string; title: string; artist: string; key: string };

export default function MeetingAgendaEditor<T extends MeetingWithAgenda>({
  meeting,
  songs,
  canEdit,
  onMeetingChange,
  onSongOpen,
  onOpenLibrary,
  showSectionNavigation = false,
}: {
  meeting: T;
  songs: Song[];
  canEdit: boolean;
  onMeetingChange: (meeting: T) => void;
  onSongOpen?: (songId: string) => void;
  onOpenLibrary?: () => void;
  showSectionNavigation?: boolean;
}) {
  const [newSectionType, setNewSectionType] = useState('');
  const [songDrafts, setSongDrafts] = useState<Record<string, string>>({});
  const [activityDrafts, setActivityDrafts] = useState<Record<string, string>>({});
  const sections = getMeetingSections(meeting);

  const updateSections = (update: (current: MeetingSection[]) => MeetingSection[]) => {
    if (!canEdit) return;
    onMeetingChange(saveMeetingSections(meeting, update(getMeetingSections(meeting))));
  };

  const addSection = () => {
    if (!meetingSectionOptions.some(option => option.type === newSectionType)) return;
    const section: MeetingSection = {
      id: crypto.randomUUID(),
      type: newSectionType as MeetingSection['type'],
      estimatedMinutes: 0,
      items: [],
    };
    updateSections(current => [...current, section]);
    setNewSectionType('');
  };

  const deleteSection = (section: MeetingSection) => {
    if (section.type === 'legacy' && section.items.length) {
      window.alert('Mueve o quita primero las canciones del repertorio anterior para conservar la agenda original.');
      return;
    }
    const message = section.items.length
      ? `¿Quitar “${sectionLabel(section.type)}” y sus ${section.items.length} elementos de esta reunión? Las canciones no se borrarán de la biblioteca.`
      : `¿Quitar la sección “${sectionLabel(section.type)}” de esta reunión?`;
    if (!window.confirm(message)) return;
    updateSections(current => current.filter(item => item.id !== section.id));
  };

  const addSong = (sectionId: string) => {
    const songId = songDrafts[sectionId];
    if (!songId) return;
    const item: MeetingAgendaItem = { id: crypto.randomUUID(), type: 'song', songId };
    updateSections(current => current.map(section => section.id === sectionId
      ? { ...section, items: [...section.items, item] }
      : section));
    setSongDrafts(current => ({ ...current, [sectionId]: '' }));
  };

  const addActivity = (sectionId: string) => {
    const text = (activityDrafts[sectionId] || '').trim();
    if (!text) return;
    const item: MeetingAgendaItem = { id: crypto.randomUUID(), type: 'activity', text };
    updateSections(current => current.map(section => section.id === sectionId
      ? { ...section, items: [...section.items, item] }
      : section));
    setActivityDrafts(current => ({ ...current, [sectionId]: '' }));
  };

  const minutes = getMeetingDuration(sections);

  return <section className="meeting-agenda">
    <div className="section-head">
      <div>
        <span className="eyebrow">ORDEN DEL SERVICIO</span>
        <h2>Agenda por secciones</h2>
        <p className="agenda-total">Duración estimada: <b>{minutes} min</b></p>
      </div>
      {onOpenLibrary&&<button className="secondary" onClick={onOpenLibrary}>
        <Music2 size={16}/> Consultar repertorio
      </button>}
    </div>

    {showSectionNavigation&&sections.length>1&&<nav className="meeting-section-navigation" aria-label="Secciones de esta reunión">
      <span>Ir a:</span>
      {sections.map((section,index)=><button type="button" key={section.id} onClick={()=>document.getElementById(`meeting-section-${section.id}`)?.scrollIntoView({behavior:'smooth',block:'start'})}>
        {index+1}. {sectionLabel(section.type)}
      </button>)}
    </nav>}

    {canEdit&&<div className="agenda-add-section">
      <label className="field"><span>Agregar una sección</span>
        <select value={newSectionType} onChange={event=>setNewSectionType(event.target.value)}>
          <option value="">Elige una sección</option>
          {meetingSectionOptions.map(option=><option key={option.type} value={option.type}>{option.label}</option>)}
        </select>
      </label>
      <button type="button" className="primary" disabled={!newSectionType} onClick={addSection}><Plus size={16}/> Agregar sección</button>
    </div>}

    {!sections.length
      ? <div className="empty"><div><Music2/></div><h3>Agenda vacía</h3><p>{canEdit?'Agrega una sección para empezar a organizar esta reunión.':'Esta reunión todavía no tiene secciones ni canciones.'}</p></div>
      : <div className="agenda-sections">{sections.map((section, sectionIndex)=>{
        const label = sectionLabel(section.type);
        const canEditSection = canEdit && section.type !== 'legacy';
        return <article className="form-card agenda-section" id={showSectionNavigation?`meeting-section-${section.id}`:undefined} key={section.id}>
          <div className="agenda-section-header">
            <div><span className="eyebrow">SECCIÓN {sectionIndex+1}</span><h3>{label}</h3></div>
            <div className="agenda-section-actions">
              {canEditSection&&<label className="field agenda-minutes"><span>Minutos estimados</span><input type="number" min="0" step="1" value={section.estimatedMinutes} onChange={event=>{const parsed=Number(event.target.value);const value=Number.isFinite(parsed)?Math.max(0,Math.floor(parsed)):0;updateSections(current=>current.map(item=>item.id===section.id?{...item,estimatedMinutes:value}:item));}}/></label>}
              {!canEditSection&&<span className="pill">{section.estimatedMinutes} min</span>}
              {canEditSection&&<>
                <button type="button" className="icon-button" aria-label="Subir sección" disabled={sectionIndex===0} onClick={()=>updateSections(current=>reorderMeetingSection(current,section.id,-1))}><ArrowUp size={16}/></button>
                <button type="button" className="icon-button" aria-label="Bajar sección" disabled={sectionIndex===sections.length-1} onClick={()=>updateSections(current=>reorderMeetingSection(current,section.id,1))}><ArrowDown size={16}/></button>
                <button type="button" className="icon-button" aria-label="Eliminar sección" onClick={()=>deleteSection(section)}><Trash2 size={16}/></button>
              </>}
            </div>
          </div>

          {section.type==='legacy'&&<p className="agenda-legacy-note">Estas canciones provienen de la agenda anterior. Muévelas a una sección para organizarlas.</p>}

          {section.items.length===0
            ? <p className="agenda-empty-items">Todavía no hay canciones ni actividades en esta sección.</p>
            : <div className="agenda-items">{section.items.map((item,itemIndex)=>{
              const song=item.type==='song'?songs.find(candidate=>candidate.id===item.songId):undefined;
              return <div className="agenda-item" key={item.id}>
                {item.type==='song'
                  ? song
                    ? onSongOpen?<button type="button" className="agenda-song" onClick={()=>onSongOpen(song.id)}>
                        <span className="song-icon"><Music2 size={17}/></span><span><b>{song.title}</b><small>{song.artist||'Artista no especificado'} · {song.key}</small></span><ChevronRight size={17}/>
                      </button>:<div className="agenda-song">
                        <span className="song-icon"><Music2 size={17}/></span><span><b>{song.title}</b><small>{song.artist||'Artista no especificado'} · {song.key}</small></span>
                      </div>
                    : <div className="agenda-song missing-song"><span className="song-icon"><Music2 size={17}/></span><span><b>Canción no disponible</b><small>Referencia: {item.songId}</small></span></div>
                  : <label className="field agenda-activity"><span>Actividad o indicación</span><textarea rows={2} maxLength={1000} value={item.text} readOnly={!canEdit} onChange={event=>updateSections(current=>current.map(currentSection=>currentSection.id===section.id?{...currentSection,items:currentSection.items.map(currentItem=>currentItem.id===item.id&&currentItem.type==='activity'?{...currentItem,text:event.target.value}:currentItem)}:currentSection))}/></label>}

                {canEdit&&<div className="agenda-item-actions">
                  {sections.some(candidate=>candidate.id!==section.id&&candidate.type!=='legacy')&&<label className="field agenda-move"><span>Mover a</span><select value={section.id} onChange={event=>updateSections(current=>moveMeetingItem(current,section.id,item.id,event.target.value))}><option value={section.id} disabled>{label}</option>{sections.filter(candidate=>candidate.id!==section.id&&candidate.type!=='legacy').map(candidate=><option key={candidate.id} value={candidate.id}>{sectionLabel(candidate.type)}</option>)}</select></label>}
                  <button type="button" className="icon-button" aria-label="Subir elemento" disabled={itemIndex===0} onClick={()=>updateSections(current=>reorderMeetingItem(current,section.id,item.id,-1))}><ArrowUp size={15}/></button>
                  <button type="button" className="icon-button" aria-label="Bajar elemento" disabled={itemIndex===section.items.length-1} onClick={()=>updateSections(current=>reorderMeetingItem(current,section.id,item.id,1))}><ArrowDown size={15}/></button>
                  <button type="button" className="icon-button" aria-label="Quitar elemento" onClick={()=>updateSections(current=>removeMeetingItem(current,section.id,item.id))}><Trash2 size={15}/></button>
                </div>}
              </div>;
            })}</div>}

          {canEditSection&&<div className="agenda-add-items">
            <div className="agenda-add-song">
              <label className="field"><span>Agregar canción del repertorio</span><select value={songDrafts[section.id]||''} onChange={event=>setSongDrafts(current=>({...current,[section.id]:event.target.value}))}>
                <option value="">Selecciona una canción</option>{songs.map(song=><option key={song.id} value={song.id}>{song.title}{song.artist?` · ${song.artist}`:''}</option>)}
              </select></label>
              <button type="button" className="secondary" disabled={!songDrafts[section.id]} onClick={()=>addSong(section.id)}><Plus size={15}/> Añadir canción</button>
            </div>
            <div className="agenda-add-song">
              <label className="field"><span>Agregar actividad o indicación</span><textarea rows={2} value={activityDrafts[section.id]||''} maxLength={1000} placeholder="Escribe una actividad..." onChange={event=>setActivityDrafts(current=>({...current,[section.id]:event.target.value}))}/></label>
              <button type="button" className="secondary" disabled={!(activityDrafts[section.id]||'').trim()} onClick={()=>addActivity(section.id)}><Save size={15}/> Añadir actividad</button>
            </div>
          </div>}
        </article>;
      })}</div>}
  </section>;
}
