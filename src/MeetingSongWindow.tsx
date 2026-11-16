import { ArrowLeft, ChevronLeft, ChevronRight, Clock3, Pause, Play, RotateCcw, X } from 'lucide-react';

type Song = { id:string; title:string; artist:string; key:string; bpm:number; lyrics:string; chords:string; sections:string; mixedText?:string };

const formatTimer=(seconds:number)=>{
  const hours=Math.floor(seconds/3600);
  const minutes=Math.floor((seconds%3600)/60);
  const remainder=seconds%60;
  return hours?`${String(hours).padStart(2,'0')}:${String(minutes).padStart(2,'0')}:${String(remainder).padStart(2,'0')}`:`${String(minutes).padStart(2,'0')}:${String(remainder).padStart(2,'0')}`;
};

export default function MeetingSongWindow({
  song, isAdditional, sectionName, songSectionName, sectionElapsed, estimatedMinutes, isCurrentSection, sectionRunning,
  canControlSection, onSectionStart, onSectionPause, generalElapsed, generalRunning, canControlGeneral,
  generalMeetingInProgress, onGeneralStart, onGeneralPause, onGeneralReset, onClose, hasPrevious,
  hasNext, onPrevious, onNext, songTab, onSongTabChange,
}: {
  song:Song; isAdditional:boolean; sectionName:string; songSectionName?:string; sectionElapsed:number; estimatedMinutes:number;
  isCurrentSection:boolean; sectionRunning:boolean; canControlSection:boolean; onSectionStart:()=>void;
  onSectionPause:()=>void; generalElapsed:number; generalRunning:boolean; canControlGeneral:boolean;
  generalMeetingInProgress:boolean; onGeneralStart:()=>void; onGeneralPause:()=>void; onGeneralReset:()=>void;
  onClose:()=>void; hasPrevious:boolean; hasNext:boolean; onPrevious:()=>void; onNext:()=>void;
  songTab:string; onSongTabChange:(tab:string)=>void;
}) {
  const overEstimate=estimatedMinutes>0&&sectionElapsed>estimatedMinutes*60;
  const mixedContent=song.mixedText?.trim()||(song.id==='libre-soy'
    ? 'INTRO: Am - F - C - G\n\nESTROFA 1\nAm\nSalvo soy, mi alegría está en tu amor\n                         F\nHoy te exaltaré, día y noche adoraré\n       C                         G\nPorque libre soy en Ti, eres todo mi vivir'
    : song.chords?song.chords+'\n\n'+song.lyrics:song.lyrics||'Esta canción todavía no tiene contenido guardado.');

  return <div className="overlay meeting-song-overlay"><div className="modal song-modal meeting-song-modal meeting-song-window" role="dialog" aria-modal="true" aria-labelledby="meeting-song-title">
    <button className="close" aria-label="Cerrar canción" onClick={onClose}><X/></button>
    <button className="back" onClick={onClose}><ArrowLeft size={16}/> Volver a la reunión</button>

    <section className={`song-window-section${overEstimate?' over-time':''}`} aria-label="Sección actual">
      <div><span className="eyebrow">{isCurrentSection?'SECCIÓN ACTUAL':'SECCIÓN DE LA CANCIÓN'}</span><h3>{sectionName}</h3></div>
      <div className="song-window-section-clock"><Clock3 size={16}/><b>{formatTimer(sectionElapsed)}</b><small>Estimado: {estimatedMinutes} min{overEstimate?' · Tiempo superado':''}</small></div>
      {canControlSection&&<div className="song-window-controls">
        {sectionRunning?<button className="secondary small" onClick={onSectionPause}><Pause size={14}/> Pausar sección</button>:<button className="secondary small" onClick={onSectionStart}><Play size={14}/> {isCurrentSection?'Reanudar sección':'Iniciar sección'}</button>}
      </div>}
    </section>

    <div className="song-window-song">
      <span className="eyebrow">{song.artist||'Artista no especificado'} · {song.key||'—'} · {song.bpm||'—'} BPM{isAdditional?' · ADICIONAL':''}</span>
      <h2 id="meeting-song-title">{song.title}</h2>
      {songSectionName&&<small className="song-window-song-section">En la agenda: {songSectionName}</small>}
      <div className="song-window-navigation" aria-label="Navegación de canciones">
        <button className="secondary small" disabled={!hasPrevious} onClick={onPrevious}><ChevronLeft size={16}/> Anterior</button>
        <button className="secondary small" disabled={!hasNext} onClick={onNext}>Siguiente <ChevronRight size={16}/></button>
      </div>
      <div className="tabs" role="tablist" aria-label="Formato de canción">{['Letra','Mixto','Acordes'].map(format=><button type="button" role="tab" aria-selected={songTab===format} className={songTab===format?'selected':''} onClick={()=>onSongTabChange(format)} key={format}>{format}</button>)}</div>
      <div className={songTab==='Mixto'?'lyrics mixed-lyrics':'lyrics'}>{songTab==='Letra'?song.lyrics||'Esta canción todavía no tiene letra guardada.':songTab==='Acordes'?<pre className="mixed-score guide-score">{song.sections||'Aún no se ha definido la guía de acordes.'}</pre>:<pre className="mixed-score">{mixedContent}</pre>}</div>
    </div>

    <section className="song-window-general" aria-label="Cronómetro general de la reunión">
      <div><span className="eyebrow">TIEMPO DE REUNIÓN</span><b className="song-window-general-time">{formatTimer(generalElapsed)}</b></div>
      {canControlGeneral&&generalMeetingInProgress?<div className="timer-actions">
        <button className="primary small" onClick={generalRunning?onGeneralPause:onGeneralStart}>{generalRunning?<Pause size={15}/>:<Play size={15}/>} {generalRunning?'Pausar':generalElapsed?'Reanudar':'Iniciar'}</button>
        <button className="secondary small" onClick={onGeneralReset}><RotateCcw size={15}/> Reiniciar</button>
      </div>:<small className="live-readonly-note">{generalMeetingInProgress?'Solo Propietarios y Administradores pueden controlar el cronómetro.':'El cronómetro general se mantiene compartido mientras consultas la canción.'}</small>}
    </section>
  </div></div>;
}
