import { useEffect, useState } from 'react';
import type { FormEvent } from 'react';
import { Camera, Check, Mail, Save, ShieldCheck, UserRound, X } from 'lucide-react';
import type { PublicProfile } from './lib/workspace';
import { getMyBirthday, getProfile, removeProfilePhoto, saveMyProfile, uploadProfilePhoto } from './lib/workspace';
import { supabase } from './lib/supabase';

const roles = ['Líder', 'Músico', 'Sonido', 'Multimedia'];

export default function ProfilePanel({ userId, email, profile, onProfileUpdate }: {
  userId: string;
  email: string;
  profile: PublicProfile;
  onProfileUpdate: (profile: PublicProfile) => void;
}) {
  const [name, setName] = useState(profile.full_name);
  const [role, setRole] = useState(profile.role);
  const [instruments, setInstruments] = useState(profile.instruments || '');
  const [birthday, setBirthday] = useState('');
  const [photo, setPhoto] = useState<File | null>(null);
  const [preview, setPreview] = useState<string | null>(profile.avatar_url || null);
  const [removePhoto, setRemovePhoto] = useState(false);
  const [newEmail, setNewEmail] = useState(email);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');

  useEffect(() => {
    let alive = true;
    void getMyBirthday(userId).then(value => { if (alive) setBirthday(value); }).catch(() => {
      if (alive) setError('No pudimos cargar tu fecha de nacimiento. Intenta actualizar la página.');
    });
    return () => { alive = false; };
  }, [userId]);

  useEffect(() => () => { if (preview?.startsWith('blob:')) URL.revokeObjectURL(preview); }, [preview]);

  const selectPhoto = (file?: File) => {
    setError(''); setMessage('');
    if (!file) return;
    if (!file.type.startsWith('image/')) { setError('Elige una foto JPG, PNG o WEBP.'); return; }
    if (file.size > 5 * 1024 * 1024) { setError('La foto debe pesar menos de 5 MB.'); return; }
    setPhoto(file); setRemovePhoto(false); setPreview(URL.createObjectURL(file));
  };

  const save = async (event: FormEvent) => {
    event.preventDefault(); setBusy(true); setError(''); setMessage('');
    let uploadedPath: string | null = null;
    try {
      const oldPath = profile.avatar_path;
      if (photo) uploadedPath = await uploadProfilePhoto(userId, photo);
      const avatarPath = photo ? uploadedPath : removePhoto ? null : oldPath;
      const updated = await saveMyProfile({ userId, fullName: name, role, instruments, birthday, avatarPath });
      onProfileUpdate(updated);
      setPhoto(null); setRemovePhoto(false); setPreview(updated.avatar_url || null);
      if (oldPath && oldPath !== avatarPath) await removeProfilePhoto(oldPath).catch(() => undefined);
      setMessage('Tu perfil quedó actualizado.');
    } catch (reason) {
      if (uploadedPath) await removeProfilePhoto(uploadedPath).catch(() => undefined);
      setError(reason instanceof Error ? reason.message : 'No se pudieron guardar los cambios.');
    } finally { setBusy(false); }
  };

  const changeEmail = async () => {
    setBusy(true); setError(''); setMessage('');
    try {
      if (!supabase) throw new Error('La conexión de UNARA no está disponible.');
      const { error: authError } = await supabase.auth.updateUser({ email: newEmail.trim() }, { emailRedirectTo: window.location.origin });
      if (authError) throw authError;
      setMessage('Revisa el correo nuevo y el anterior para confirmar el cambio.');
    } catch (reason) { setError(reason instanceof Error ? reason.message : 'No se pudo solicitar el cambio de correo.'); }
    finally { setBusy(false); }
  };

  return <div className="profile-page">
    <div className="section-head"><div><span className="eyebrow">TU CUENTA</span><h2>Tu perfil</h2><p>Actualiza tus datos y la foto que verá tu equipo.</p></div></div>
    <form className="profile-card" onSubmit={save}>
      <div className="profile-photo-row">
        <div className="profile-photo">{preview ? <img src={preview} alt="Foto de perfil"/> : <UserRound size={38}/>}</div>
        <div className="profile-photo-actions"><b>Foto de perfil</b><small>JPG, PNG o WEBP · máximo 5 MB</small><div className="profile-photo-buttons"><label className="secondary small photo-picker"><Camera size={15}/> Elegir foto<input type="file" accept="image/jpeg,image/png,image/webp" onChange={event=>selectPhoto(event.target.files?.[0])}/></label>{preview&&<button className="secondary small" type="button" onClick={()=>{setPhoto(null);setRemovePhoto(true);setPreview(null)}}><X size={15}/> Quitar</button>}</div></div>
      </div>
      <div className="form-grid profile-form-grid">
        <label className="field"><span>Nombre</span><input required minLength={2} maxLength={80} value={name} onChange={event=>setName(event.target.value)} placeholder="Tu nombre"/></label>
        <label className="field"><span>Cargo</span><select value={role} onChange={event=>setRole(event.target.value)}>{roles.map(item=><option key={item}>{item}</option>)}</select></label>
        <label className="field"><span>Fecha de nacimiento <small>(privada)</small></span><input required type="date" value={birthday} onChange={event=>setBirthday(event.target.value)}/></label>
        <label className="field"><span>Instrumentos o funciones</span><input maxLength={160} value={instruments} onChange={event=>setInstruments(event.target.value)} placeholder="Ej. Voz, guitarra, teclado"/></label>
      </div>
      <p className="profile-privacy"><ShieldCheck size={16}/> Tu fecha de nacimiento solo la puedes ver tú.</p>
      <button className="primary" type="submit" disabled={busy}><Save size={16}/>{busy?'Guardando…':'Guardar cambios'}</button>
    </form>
    <section className="profile-card profile-account-card"><div><span className="eyebrow">ACCESO A LA CUENTA</span><h3>Correo electrónico</h3><p>Para cambiarlo, confirma la solicitud desde tus correos.</p></div><label className="field"><span>Correo nuevo</span><input type="email" required value={newEmail} onChange={event=>setNewEmail(event.target.value)} placeholder={email}/></label><button className="secondary" type="button" disabled={busy||newEmail.trim().toLowerCase()===email.trim().toLowerCase()} onClick={()=>void changeEmail()}><Mail size={16}/> Solicitar cambio de correo</button></section>
    {(error||message)&&<div role={error?'alert':'status'} className={`auth-status ${error?'error-status':''}`}>{error||<><Check size={15}/> {message}</>}</div>}
  </div>;
}
