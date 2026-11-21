import { ReactNode, useEffect, useRef, useState } from 'react';
import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, ChevronRight, ChevronDown, Info, Music2, Plus, Save, Trash2, Play, Pause, RotateCcw, Clock3 } from 'lucide-react';
import {
  getMeetingDuration,
  getMeetingSections,
  mergeMeetingLiveSongs,
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
import { MeetingLiveSong, MeetingSectionTimer, formatLiveSectionTime, liveElapsedSeconds, liveSectionRemainingSeconds } from './lib/meetingLive';

type Song = { id: string; title: string; artist: string; key: string; bpm?: number; lyrics?: string; chords?: string; sections?: string; mixedText?: string };

export default function MeetingAgendaEditor<T extends MeetingWithAgenda>({
  meeting,
  songs,
  canEdit,
  onMeetingChange,
  onSongOpen,
  onOpenLibrary,
  showSectionNavigation = false,
  liveMode = false,
  liveSectionId = null,
  liveSongs = [],
  sectionTimers = {},
  currentSectionId = null,
  liveNow = Date.now(),
  canControlLive = false,
  liveActionPending = false,
  canAddLiveSongs = false,
  editorMode = false,
  generalPanel,
  teamPanel,
  onSave,
  finalActionLabel = 'Publicar cambios',
  saving = false,
  saveDisabled = false,
  onStartSection,
  onSectionTimerAction,
  onAddLiveSong,
}: {
  meeting: T;
  songs: Song[];
  canEdit: boolean;
  onMeetingChange: (meeting: T) => void;
  onSongOpen?: (song: { songId: string; itemId: string; sectionId: string }) => void;
  onOpenLibrary?: () => void;
  showSectionNavigation?: boolean;
  liveMode?: boolean;
  liveSectionId?: string | null;
  liveSongs?: MeetingLiveSong[];
  sectionTimers?: Record<string, MeetingSectionTimer>;
  currentSectionId?: string | null;
  liveNow?: number;
  canControlLive?: boolean;
  liveActionPending?: boolean;
  canAddLiveSongs?: boolean;
  editorMode?: boolean;
  generalPanel?: ReactNode;
  teamPanel?: ReactNode;
  onSave?: () => void;
  finalActionLabel?: string;
  saving?: boolean;
  saveDisabled?: boolean;
  onStartSection?: (sectionId: string) => void;
  onSectionTimerAction?: (sectionId: string, action: 'section_pause' | 'section_reset') => void;
  onAddLiveSong?: (sectionId: string, songId: string, afterItemId: string | null) => Promise<boolean | void>;
}) {
  const [newSectionType, setNewSectionType] = useState('');
  const [songDrafts, setSongDrafts] = useState<Record<string, string>>({});
  const [activityDrafts, setActivityDrafts] = useState<Record<string, string>>({});
  const [liveSongDrafts, setLiveSongDrafts] = useState<Record<string, string>>({});
  const [liveSongPositions, setLiveSongPositions] = useState<Record<string, string>>({});
  const [addingLiveSong, setAddingLiveSong] = useState<string | null>(null);
  const [expandedLiveSongs, setExpandedLiveSongs] = useState<Record<string, boolean>>({});
  const [liveSongFormats, setLiveSongFormats] = useState<Record<string, 'Letra' | 'Mixto' | 'Acordes'>>({});
  const [activeEditorTab, setActiveEditorTab] = useState<string>('general');
  const editorTabsRef = useRef<HTMLElement>(null);
  const editorContentRef = useRef<HTMLDivElement>(null);
  const sections = getMeetingSections(meeting);

  useEffect(() => {
    if (!editorMode) return;
    if (activeEditorTab === 'general' || (activeEditorTab === 'team' && !!teamPanel) || sections.some(section => section.id === activeEditorTab)) return;
    setActiveEditorTab('general');
  }, [editorMode, activeEditorTab, sections, teamPanel]);

  useEffect(() => {
    if (!editorMode) return;
    const modal = editorTabsRef.current?.closest<HTMLElement>('.meeting-editor-redesigned');
    if (!modal) return;
    const viewport = window.visualViewport;
    const syncViewport = () => {
      const height = viewport?.height || window.innerHeight;
      modal.style.setProperty('--meeting-editor-viewport-height', `${height}px`);
      modal.style.setProperty('--meeting-editor-viewport-offset-top', `${viewport?.offsetTop || 0}px`);
      modal.classList.toggle('keyboard-open', !!viewport && window.innerHeight - viewport.height > 120);
    };
    syncViewport();
    viewport?.addEventListener('resize', syncViewport);
    viewport?.addEventListener('scroll', syncViewport);
    window.addEventListener('resize', syncViewport);
    return () => {
      viewport?.removeEventListener('resize', syncViewport);
      viewport?.removeEventListener('scroll', syncViewport);
      window.removeEventListener('resize', syncViewport);
      modal.style.removeProperty('--meeting-editor-viewport-height');
      modal.style.removeProperty('--meeting-editor-viewport-offset-top');
      modal.classList.remove('keyboard-open');
    };
  }, [editorMode]);

  useEffect(() => {
    if (!editorMode || !activeEditorTab) return;
    const tabs = editorTabsRef.current;
    const activeTab = tabs?.querySelector<HTMLElement>('[data-active="true"]');
    if (tabs && activeTab) tabs.scrollTo({ left: activeTab.offsetLeft - (tabs.clientWidth - activeTab.clientWidth) / 2, behavior: 'smooth' });
    editorContentRef.current?.scrollTo({ top: 0, left: 0, behavior: 'instant' });
  }, [editorMode, activeEditorTab, sections.map(section => section.id).join('|')]);

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
    if (editorMode && activeEditorTab === section.id) {
      const index = sections.findIndex(item => item.id === section.id);
      setActiveEditorTab('general');
    }
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
  const isGeneralStep = editorMode && activeEditorTab === 'general';
  const isTeamStep = editorMode && activeEditorTab === 'team';
  const visibleSections = editorMode
    ? sections.filter(section => section.id === activeEditorTab)
    : liveMode
      ? sections.filter(section => section.id === liveSectionId)
      : sections;
  const editorSteps = editorMode ? ['general', ...sections.map(section => section.id), ...(teamPanel ? ['team'] : [])] : [];
  const editorStepIndex = Math.max(0, editorSteps.indexOf(activeEditorTab));
  const addSectionControl = <div className="agenda-add-section">
    <label className="field"><span>Agregar una sección</span>
      <select value={newSectionType} onChange={event=>setNewSectionType(event.target.value)}>
        <option value="">Elige una sección</option>
        {meetingSectionOptions.map(option=><option key={option.type} value={option.type}>{option.label}</option>)}
      </select>
    </label>
    <button type="button" className="primary" disabled={!newSectionType} onClick={addSection}><Plus size={16}/> Agregar sección</button>
  </div>;
  const moveWithinType = (section: MeetingSection, itemId: string, direction: -1 | 1) => {
    const item = section.items.find(entry => entry.id === itemId);
    if (!item) return;
    updateSections(current => current.map(candidate => {
      if (candidate.id !== section.id) return candidate;
      const indices = candidate.items.flatMap((entry, index) => entry.type === item.type ? [index] : []);
      const currentIndex = indices.indexOf(candidate.items.findIndex(entry => entry.id === itemId));
      const nextIndex = currentIndex + direction;
      if (currentIndex < 0 || nextIndex < 0 || nextIndex >= indices.length) return candidate;
      const items = [...candidate.items];
      [items[indices[currentIndex]], items[indices[nextIndex]]] = [items[indices[nextIndex]], items[indices[currentIndex]]];
      return { ...candidate, items };
    }));
  };

  return <section className="meeting-agenda">
    {!editorMode&&<div className="section-head">
      <div>
        <span className="eyebrow">ORDEN DEL SERVICIO</span>
        <h2>Agenda por secciones</h2>
        <p className="agenda-total">Duración estimada: <b>{minutes} min</b></p>
      </div>
      {onOpenLibrary&&<button className="secondary" onClick={onOpenLibrary}>
        <Music2 size={16}/> Consultar repertorio
      </button>}
    </div>}

    {editorMode&&<nav className="meeting-editor-tabs" ref={editorTabsRef} aria-label="Pestañas del editor de reunión">
      <button type="button" data-active={isGeneralStep} aria-selected={isGeneralStep} className={isGeneralStep?'selected':''} onClick={()=>setActiveEditorTab('general')}>General</button>
      {sections.map((section,index)=><button type="button" key={section.id} data-active={activeEditorTab===section.id} aria-selected={activeEditorTab===section.id} className={activeEditorTab===section.id?'selected':''} onClick={()=>setActiveEditorTab(section.id)}>{index+1} {sectionLabel(section.type)}</button>)}
      {teamPanel&&<button type="button" data-active={activeEditorTab==='team'} aria-selected={activeEditorTab==='team'} className={activeEditorTab==='team'?'selected':''} onClick={()=>setActiveEditorTab('team')}>Equipo</button>}
    </nav>}

    {!editorMode&&showSectionNavigation&&sections.length>1&&<nav className="meeting-section-navigation" aria-label="Secciones de esta reunión">
      <span>Ir a:</span>
      {sections.map((section,index)=><button type="button" key={section.id} onClick={()=>document.getElementById(`meeting-section-${section.id}`)?.scrollIntoView({behavior:'smooth',block:'start'})}>
        {index+1}. {sectionLabel(section.type)}
      </button>)}
    </nav>}

    {!editorMode&&canEdit&&addSectionControl}

    {isGeneralStep&&<div className="meeting-editor-general-scroll" ref={editorContentRef}>
      {generalPanel}
      <section className="meeting-editor-sections-organizer">
        <div className="meeting-editor-organizer-heading"><div><h3>Organización de secciones</h3><span>Orden del servicio · {minutes} min estimados</span></div></div>
        {canEdit&&addSectionControl}
        {sections.length===0?<p className="meeting-editor-no-sections">Todavía no agregas secciones. Puedes continuar y agregarlas después.</p>:<ol className="meeting-editor-section-list">{sections.map((section,index)=><li className="meeting-editor-section-row" key={section.id}>
          <span className="meeting-editor-section-number">{index+1}</span>
          <span className={`meeting-editor-section-color section-${section.type}`} aria-hidden="true"/>
          <b>{sectionLabel(section.type)}</b>
          <span className="meeting-editor-section-count">{section.items.length} elementos</span>
          {canEdit&&<div className="meeting-editor-section-row-actions">
            <button type="button" className="icon-button" aria-label={`Subir ${sectionLabel(section.type)}`} disabled={index===0} onClick={()=>updateSections(current=>reorderMeetingSection(current,section.id,-1))}><ArrowUp size={15}/></button>
            <button type="button" className="icon-button" aria-label={`Bajar ${sectionLabel(section.type)}`} disabled={index===sections.length-1} onClick={()=>updateSections(current=>reorderMeetingSection(current,section.id,1))}><ArrowDown size={15}/></button>
            <button type="button" className="icon-button" aria-label={`Eliminar ${sectionLabel(section.type)}`} onClick={()=>deleteSection(section)}><Trash2 size={15}/></button>
          </div>}
        </li>)}</ol>}
      </section>
    </div>}

    {isTeamStep&&teamPanel&&<div className="meeting-editor-team-scroll" ref={editorContentRef}>{teamPanel}</div>}

    {(!editorMode||(!isGeneralStep&&!isTeamStep))&&(!sections.length
      ? <div className="empty"><div><Music2/></div><h3>Agenda vacía</h3><p>{canEdit?'Agrega una sección para empezar a organizar esta reunión.':'Esta reunión todavía no tiene secciones ni canciones.'}</p></div>
      : <div ref={editorMode?editorContentRef:undefined} className={`agenda-sections${editorMode?' editor-agenda-sections':''}`}>{visibleSections.map((section)=>{
        const sectionIndex = sections.findIndex(candidate => candidate.id === section.id);
        const label = sectionLabel(section.type);
        const canEditSection = canEdit && section.type !== 'legacy';
        const sectionLiveSongs = liveSongs.filter(song => song.section_id === section.id);
        const mergedItems = mergeMeetingLiveSongs(section.items, sectionLiveSongs);
        const timer = sectionTimers[section.id];
        const timerElapsed = liveElapsedSeconds(timer?.elapsed_seconds || 0, timer?.started_at || null, !!timer?.is_running, liveNow);
        const hasEstimate = section.estimatedMinutes > 0;
        const remainingSeconds = liveSectionRemainingSeconds(section.estimatedMinutes, timerElapsed);
        const zeroEstimateOvertime = !hasEstimate && !!timer && timerElapsed > 0;
        const overEstimate = hasEstimate && timerElapsed > section.estimatedMinutes * 60 || zeroEstimateOvertime;
        const sectionClock = hasEstimate
          ? formatLiveSectionTime(remainingSeconds, overEstimate)
          : timer
            ? formatLiveSectionTime(timerElapsed, zeroEstimateOvertime)
            : '—:—';
        const renderItem=(item:typeof mergedItems[number])=>{
          const song=item.type==='song'?songs.find(candidate=>candidate.id===item.songId):undefined;
           if(liveMode&&item.type==='activity')return null;
           if(liveMode&&item.type==='song'){
             const songIndex=songsOnly.findIndex(entry=>entry.id===item.id);
             const expanded=expandedLiveSongs[item.id]??songIndex===0;
             const format=liveSongFormats[item.id]||'Mixto';
             const mixedContent=song?.mixedText?.trim()||(song?.id==='libre-soy'?'INTRO: Am - F - C - G\n\nESTROFA 1\nAm\nSalvo soy, mi alegría está en tu amor\n                         F\nHoy te exaltaré, día y noche adoraré\n       C                         G\nPorque libre soy en Ti, eres todo mi vivir':song?.chords?`${song.chords}\n\n${song.lyrics||''}`:song?.lyrics||'Esta canción todavía no tiene contenido guardado.');
             return <article className={`live-song-card${expanded?' expanded':''}${'isLive' in item&&item.isLive?' is-additional':''}`} key={item.id}>
               <button type="button" className="live-song-heading" aria-expanded={expanded} onClick={()=>setExpandedLiveSongs(current=>({...current,[item.id]:!expanded}))}>
                 <span className="song-icon"><Music2 size={19}/></span>
                 <span className="live-song-heading-copy"><b>{song?.title||'Canción no disponible'}{'isLive' in item&&item.isLive&&<em className="live-song-badge">Adicional</em>}</b><small>{song?`${song.artist||'Artista no especificado'} · ${song.key||'—'}`:'Esta referencia no está disponible en el repertorio'}</small></span>
                 <ChevronDown size={19} className="live-song-chevron"/>
               </button>
               {expanded&&song&&<div className="live-song-expanded">
                 <div className="live-song-formats" role="tablist" aria-label={`Formato de ${song.title}`}>{(['Letra','Mixto','Acordes'] as const).map(tab=><button type="button" role="tab" aria-selected={format===tab} className={format===tab?'selected':''} onClick={()=>setLiveSongFormats(current=>({...current,[item.id]:tab}))} key={tab}>{tab}</button>)}</div>
                 <div className="live-song-body">{format==='Letra'?<div className="live-song-lyrics">{song.lyrics||'Esta canción todavía no tiene letra guardada.'}</div>:format==='Acordes'?<pre className="mixed-score live-song-score">{song.sections||song.chords||'Aún no hay una guía de acordes guardada.'}</pre>:<pre className="mixed-score live-song-score">{mixedContent}</pre>}</div>
               </div>}
             </article>;
           }
          const agendaIndex=section.items.findIndex(candidate=>candidate.id===item.id);
          const sameTypeItems=section.items.filter(candidate=>candidate.type===item.type);
          const sameTypeIndex=sameTypeItems.findIndex(candidate=>candidate.id===item.id);
          return <div className="agenda-item" key={item.id}>
            {item.type==='song'
              ? song
                ? onSongOpen?<button type="button" className="agenda-song" onClick={()=>onSongOpen({songId:song.id,itemId:item.id,sectionId:section.id})}>
                    <span className="song-icon"><Music2 size={17}/></span><span><b>{song.title}{'isLive' in item&&item.isLive&&<em className="live-song-badge">Adicional</em>}</b><small>{song.artist||'Artista no especificado'} · {song.key}</small></span><ChevronRight size={17}/>
                  </button>:<div className="agenda-song"><span className="song-icon"><Music2 size={17}/></span><span><b>{song.title}{'isLive' in item&&item.isLive&&<em className="live-song-badge">Adicional</em>}</b><small>{song.artist||'Artista no especificado'} · {song.key}</small></span></div>
                : <div className="agenda-song missing-song"><span className="song-icon"><Music2 size={17}/></span><span><b>Canción no disponible</b><small>Referencia: {item.songId}</small></span></div>
              : <label className="field agenda-activity"><span>{editorMode?'Indicación':'Actividad o indicación'}</span><textarea rows={2} maxLength={1000} value={item.text} readOnly={!canEdit} onChange={event=>updateSections(current=>current.map(currentSection=>currentSection.id===section.id?{...currentSection,items:currentSection.items.map(currentItem=>currentItem.id===item.id&&currentItem.type==='activity'?{...currentItem,text:event.target.value}:currentItem)}:currentSection))}/></label>}

            {canEdit&&(!('isLive' in item&&item.isLive))&&<div className="agenda-item-actions">
              {sections.some(candidate=>candidate.id!==section.id&&candidate.type!=='legacy')&&<label className="field agenda-move"><span>Mover a</span><select value={section.id} onChange={event=>updateSections(current=>moveMeetingItem(current,section.id,item.id,event.target.value))}><option value={section.id} disabled>{label}</option>{sections.filter(candidate=>candidate.id!==section.id&&candidate.type!=='legacy').map(candidate=><option key={candidate.id} value={candidate.id}>{sectionLabel(candidate.type)}</option>)}</select></label>}
              <button type="button" className="icon-button" aria-label="Subir elemento" disabled={editorMode?sameTypeIndex===0:agendaIndex===0} onClick={()=>editorMode?moveWithinType(section,item.id,-1):updateSections(current=>reorderMeetingItem(current,section.id,item.id,-1))}><ArrowUp size={15}/></button>
              <button type="button" className="icon-button" aria-label="Bajar elemento" disabled={editorMode?sameTypeIndex===sameTypeItems.length-1:agendaIndex===section.items.length-1} onClick={()=>editorMode?moveWithinType(section,item.id,1):updateSections(current=>reorderMeetingItem(current,section.id,item.id,1))}><ArrowDown size={15}/></button>
              <button type="button" className="icon-button" aria-label={item.type==='activity'?'Quitar indicación':'Quitar canción'} onClick={()=>updateSections(current=>removeMeetingItem(current,section.id,item.id))}><Trash2 size={15}/></button>
            </div>}
          </div>;
        };
        const songsOnly=mergedItems.filter(item=>item.type==='song');
        const activitiesOnly=mergedItems.filter(item=>item.type==='activity');
        return <article className={`form-card agenda-section${editorMode?' editor-agenda-section section-'+section.type:''}${liveMode?' live-agenda-section section-'+section.type:''}`} id={showSectionNavigation?`meeting-section-${section.id}`:undefined} key={section.id}>
          {liveMode&&<div className="live-section-title"><span>{sectionIndex+1} · {label}</span><b>{section.estimatedMinutes||0} min</b></div>}
          {editorMode&&<div className="meeting-editor-section-title"><span>{sectionIndex+1} · {label}</span></div>}
          <div className="agenda-section-header">
            <div><span className="eyebrow">SECCIÓN {sectionIndex+1}</span><h3>{label}</h3></div>
            <div className="agenda-section-actions">
              {canEditSection&&<label className="field agenda-minutes"><span>Minutos estimados</span><input type="number" min="0" step="1" value={section.estimatedMinutes} onChange={event=>{const parsed=Number(event.target.value);const value=Number.isFinite(parsed)?Math.max(0,Math.floor(parsed)):0;updateSections(current=>current.map(item=>item.id===section.id?{...item,estimatedMinutes:value}:item));}}/></label>}
              {!canEditSection&&<span className="pill">{section.estimatedMinutes} min</span>}
              {canEditSection&&!editorMode&&<>
                <button type="button" className="icon-button" aria-label="Subir sección" disabled={sectionIndex===0} onClick={()=>updateSections(current=>reorderMeetingSection(current,section.id,-1))}><ArrowUp size={16}/></button>
                <button type="button" className="icon-button" aria-label="Bajar sección" disabled={sectionIndex===sections.length-1} onClick={()=>updateSections(current=>reorderMeetingSection(current,section.id,1))}><ArrowDown size={16}/></button>
                <button type="button" className="icon-button" aria-label="Eliminar sección" onClick={()=>deleteSection(section)}><Trash2 size={16}/></button>
              </>}
            </div>
          </div>

          {!editorMode&&<div className={`live-section-clock${currentSectionId===section.id?' current':''}${overEstimate?' over-time':''}`}>
            <div className="live-section-clock-info"><Clock3 size={16}/><span>{currentSectionId===section.id?(timer?.is_running?'Sección actual · En curso':'Sección actual · Pausada'):timer?'Tiempo registrado':'Pendiente de inicio'}</span><b>{sectionClock}</b><small>{hasEstimate?`Estimado: ${section.estimatedMinutes} min${overEstimate?' · Tiempo superado':''}`:`Sin duración estimada${timer?' · Tiempo transcurrido':''}`}</small></div>
            {canControlLive&&<div className="live-section-clock-actions">
              {currentSectionId!==section.id&&<button type="button" className="secondary small" disabled={liveActionPending} onClick={()=>onStartSection?.(section.id)}><Play size={14}/> Iniciar sección</button>}
              {currentSectionId===section.id&&timer?.is_running&&<button type="button" className="secondary small" disabled={liveActionPending} onClick={()=>onSectionTimerAction?.(section.id,'section_pause')}><Pause size={14}/> Pausar</button>}
              {currentSectionId===section.id&&!timer?.is_running&&<button type="button" className="primary small" disabled={liveActionPending} onClick={()=>onStartSection?.(section.id)}><Play size={14}/> Reanudar</button>}
              {timerElapsed>0&&<button type="button" className="icon-button" disabled={liveActionPending} aria-label="Reiniciar cronómetro de sección" onClick={()=>onSectionTimerAction?.(section.id,'section_reset')}><RotateCcw size={14}/></button>}
            </div>}
          </div>}

          {section.type==='legacy'&&<p className="agenda-legacy-note">Estas canciones provienen de la agenda anterior. Muévelas a una sección para organizarlas.</p>}

          {liveMode?<>
            {activitiesOnly.length>0&&<details className={`live-section-instructions section-${section.type}`}><summary><Info size={18}/><b>Indicaciones de la sección</b><ChevronDown size={18} className="live-instructions-chevron"/></summary><div>{activitiesOnly.map(item=><p key={item.id}>{item.text}</p>)}</div></details>}
            {songsOnly.length>0?<div className="live-song-list">{mergedItems.filter(item=>item.type==='song').map(renderItem)}</div>:activitiesOnly.length===0?<p className="agenda-empty-items">Esta sección todavía no tiene canciones ni indicaciones.</p>:null}
          </>:editorMode?<div className="meeting-editor-columns">
            <section className="meeting-editor-column"><h3>Canciones</h3>{songsOnly.length?<div className="agenda-items">{songsOnly.map(renderItem)}</div>:<p className="agenda-empty-items">Aún no hay canciones.</p>}{canEditSection&&<div className="agenda-add-song"><label className="field"><span>Agregar canción</span><select value={songDrafts[section.id]||''} onChange={event=>setSongDrafts(current=>({...current,[section.id]:event.target.value}))}><option value="">Selecciona una canción</option>{songs.map(song=><option key={song.id} value={song.id}>{song.title}{song.artist?` · ${song.artist}`:''}</option>)}</select></label><button type="button" className="primary" disabled={!songDrafts[section.id]} onClick={()=>addSong(section.id)}><Plus size={15}/> Agregar canción</button></div>}</section>
            <section className="meeting-editor-column"><h3>Indicaciones</h3>{activitiesOnly.length?<div className="agenda-items">{activitiesOnly.map(renderItem)}</div>:<p className="agenda-empty-items">Aún no hay indicaciones.</p>}{canEditSection&&<div className="agenda-add-song"><label className="field"><span>Escribir indicación</span><textarea rows={2} value={activityDrafts[section.id]||''} maxLength={1000} placeholder="Escribe una indicación..." onChange={event=>setActivityDrafts(current=>({...current,[section.id]:event.target.value}))}/></label><button type="button" className="primary" disabled={!(activityDrafts[section.id]||'').trim()} onClick={()=>addActivity(section.id)}><Plus size={15}/> Agregar indicación</button></div>}</section>
          </div>:mergedItems.length===0
            ? <p className="agenda-empty-items">Todavía no hay canciones ni actividades en esta sección.</p>
            : <div className="agenda-items">{mergedItems.map(renderItem)}</div>}

          {!editorMode&&canEditSection&&<div className="agenda-add-items">
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

          {canAddLiveSongs&&<div className="agenda-add-items live-add-song">
            <div className="agenda-add-song">
              <label className="field"><span>Añadir canción durante la reunión</span><select value={liveSongDrafts[section.id]||''} onChange={event=>setLiveSongDrafts(current=>({...current,[section.id]:event.target.value}))}>
                <option value="">Selecciona una canción del repertorio</option>{songs.map(song=><option key={song.id} value={song.id}>{song.title}{song.artist?` · ${song.artist}`:''}</option>)}
              </select></label>
              <label className="field"><span>Colocarla después de</span><select value={liveSongPositions[section.id]??mergedItems[mergedItems.length-1]?.id??''} onChange={event=>setLiveSongPositions(current=>({...current,[section.id]:event.target.value}))}>
                <option value="">Al inicio</option>{mergedItems.map((item,index)=>{const title=item.type==='song'?songs.find(song=>song.id===item.songId)?.title||'Canción':'Actividad';return <option key={item.id} value={item.id}>{index+1}. {title}</option>})}
              </select></label>
              <button type="button" className="secondary" disabled={!liveSongDrafts[section.id]||addingLiveSong===section.id} onClick={async()=>{if(!onAddLiveSong)return;setAddingLiveSong(section.id);try{const success=await onAddLiveSong(section.id,liveSongDrafts[section.id],liveSongPositions[section.id]??mergedItems[mergedItems.length-1]?.id??null);if(success!==false)setLiveSongDrafts(current=>({...current,[section.id]:''}));}finally{setAddingLiveSong(null);}}}><Plus size={15}/> {addingLiveSong===section.id?'Añadiendo…':'Añadir canción'}</button>
            </div>
          </div>}
        </article>;
      })}</div>)}

    {editorMode&&<footer className={`meeting-editor-navigation${editorStepIndex===editorSteps.length-1?' is-final-step':''}`}>
      <button type="button" className="secondary" disabled={editorStepIndex===0} onClick={()=>setActiveEditorTab(editorSteps[Math.max(0,editorStepIndex-1)])}><ArrowLeft size={16}/> Anterior</button>
      {editorStepIndex<editorSteps.length-1
        ? <button type="button" className="primary" onClick={()=>setActiveEditorTab(editorSteps[editorStepIndex+1])}>Siguiente <ArrowRight size={16}/></button>
        : <button type="button" className="primary" onClick={onSave} disabled={saving||saveDisabled||!onSave}><Save size={16}/> {saving?'Publicando…':finalActionLabel}</button>}
    </footer>}
  </section>;
}
