import { FormEvent, useEffect, useState } from 'react';
import type { Session } from '@supabase/supabase-js';
import { ArrowRight, Eye, EyeOff, Music2, ShieldCheck } from 'lucide-react';
import { WorkspaceApp, initialSongs } from './App';
import { hasSupabaseConfig, supabase } from './lib/supabase';
import { createWorkspace, getMyWorkspace, getProfile, joinWorkspace, PublicProfile, seedWorkspace } from './lib/workspace';

const localDate = new Date();
const latestBirthday = `${localDate.getFullYear()}-${String(localDate.getMonth() + 1).padStart(2, '0')}-${String(localDate.getDate()).padStart(2, '0')}`;
type Mode = 'login' | 'signup';

export default function AuthGate() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [mode, setMode] = useState<Mode>('signup');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [passwordVisible, setPasswordVisible] = useState(false);
  const [name, setName] = useState('');
  const [birthDate, setBirthDate] = useState('');
  const [workspaceName, setWorkspaceName] = useState('Equipo de adoración');
  const [inviteCode, setInviteCode] = useState('');
  const [workspaceId, setWorkspaceId] = useState<string | null>(null);
  const [membershipPending, setMembershipPending] = useState(false);
  const [profile, setProfile] = useState<PublicProfile | null>(null);
  const [busy, setBusy] = useState(false);
  const [recoveryMode, setRecoveryMode] = useState(false);
  const [message, setMessage] = useState('');
  const [error, setError] = useState('');

  useEffect(() => {
    if (!supabase) { setLoading(false); return; }
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data: listener } = supabase.auth.onAuthStateChange((event, value) => {
      if (event === 'PASSWORD_RECOVERY') setRecoveryMode(true);
      setSession(value);
    });
    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    let alive = true;
    async function loadAccount() {
      if (!session?.user) { setWorkspaceId(null); setProfile(null); setLoading(false); return; }
      setLoading(true); setError('');
      try {
        const [userProfile, membership] = await Promise.all([
          getProfile(session.user.id),
          getMyWorkspace(session.user.id),
        ]);
        if (alive) { setProfile(userProfile); setWorkspaceId(membership?.workspace_id || null); setMembershipPending(membership?.membership_status==='pending'); }
      } catch (reason) {
        if (alive) setError(reason instanceof Error ? reason.message : 'No pudimos cargar tu cuenta.');
      } finally { if (alive) setLoading(false); }
    }
    void loadAccount();
    return () => { alive = false; };
  }, [session?.user.id]);

  const submitAuth = async (event: FormEvent) => {
    event.preventDefault(); setError(''); setMessage(''); setBusy(true);
    try {
      if (!supabase) throw new Error('Falta configurar la conexión segura.');
      if (mode === 'signup') {
        const { data, error: authError } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: { data: { full_name: name.trim(), date_of_birth: birthDate } },
        });
        if (authError) throw authError;
        if (!data.session) {
          setMode('login');
          setMessage('Te enviamos un correo para confirmar tu cuenta. Confírmalo y luego inicia sesión aquí.');
        } else setMessage('Cuenta creada. Ahora podrás crear o unirte al espacio de tu equipo.');
      } else {
        const { error: authError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
        if (authError) throw authError;
      }
    } catch (reason) { setError(reason instanceof Error ? reason.message : 'No pudimos completar la solicitud.'); }
    finally { setBusy(false); }
  };

  const resetPassword = async () => {
    setError(''); setMessage('');
    if (!email.trim()) { setError('Escribe primero tu correo para enviarte el enlace.'); return; }
    if (!supabase) return;
    const { error: resetError } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin });
    if (resetError) setError(resetError.message);
    else setMessage('Si existe una cuenta con ese correo, recibirás un enlace para cambiar la contraseña.');
  };

  const finishPasswordReset = async (event: FormEvent) => {
    event.preventDefault(); setError(''); setMessage(''); setBusy(true);
    try {
      if (!supabase) throw new Error('Falta configurar la conexión segura.');
      const { error: updateError } = await supabase.auth.updateUser({ password });
      if (updateError) throw updateError;
      setPassword(''); setRecoveryMode(false); setMode('login');
      setMessage('Contraseña actualizada. Ya puedes iniciar sesión.');
      await supabase.auth.signOut();
    } catch (reason) { setError(reason instanceof Error ? reason.message : 'No pudimos cambiar la contraseña.'); }
    finally { setBusy(false); }
  };

  const createTeam = async (event: FormEvent) => {
    event.preventDefault(); setError(''); setBusy(true);
    try {
      if (!session?.user) throw new Error('Inicia sesión para continuar.');
      const team = await createWorkspace(workspaceName);
      const savedSongs = readSaved('unara.songs', initialSongs);
      const savedMeetings = readSaved('unara.meetings', []);
      await seedWorkspace(team.id, savedSongs, savedMeetings);
      setWorkspaceId(team.id);
      setMembershipPending(false);
    } catch (reason) { setError(reason instanceof Error ? reason.message : 'No pudimos crear el espacio.'); }
    finally { setBusy(false); }
  };

  const enterTeam = async (event: FormEvent) => {
    event.preventDefault(); setError(''); setBusy(true);
    try {
      const team = await joinWorkspace(inviteCode);
      setWorkspaceId(team.id);
      setMembershipPending(true);
    } catch (reason) { setError(readErrorMessage(reason, 'No pudimos completar la unión al equipo.')); }
    finally { setBusy(false); }
  };

  if (!hasSupabaseConfig) return <SetupNeeded />;
  if (loading) return <MessageScreen>Preparando tu espacio de UNARA…</MessageScreen>;
  if (recoveryMode) return <div className="auth-page"><section className="auth-card"><Brand/><span className="eyebrow">RECUPERAR CUENTA</span><h1>Elige una contraseña nueva</h1><form onSubmit={finishPasswordReset}><label className="field"><span>Nueva contraseña</span><span className="password-input-control"><input required type={passwordVisible?'text':'password'} minLength={8} autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)} placeholder="Al menos 8 caracteres"/><button type="button" className="password-visibility" aria-label={passwordVisible?'Ocultar contraseña':'Mostrar contraseña'} aria-pressed={passwordVisible} onClick={()=>setPasswordVisible(value=>!value)}>{passwordVisible?<EyeOff size={18}/>:<Eye size={18}/>}</button></span></label><button className="primary full" disabled={busy}>{busy?'Un momento…':'Guardar contraseña'}</button></form><Status error={error} message={message}/></section></div>;
  if (session && error && !profile) return <div className="auth-page"><section className="auth-card"><Brand/><h1>No pudimos abrir tu cuenta</h1><Status error={error}/><button className="secondary full" onClick={()=>window.location.reload()}>Intentar de nuevo</button><button className="auth-text-button" onClick={()=>supabase?.auth.signOut()}>Cerrar sesión</button></section></div>;
  if (session && workspaceId && profile && membershipPending) return <div className="auth-page"><section className="auth-card"><Brand/><span className="eyebrow">SOLICITUD ENVIADA</span><h1>Esperando aprobación</h1><p>Un administrador del equipo debe aceptar tu solicitud. Cuando te acepten, pulsa el botón para entrar.</p><button className="primary full" onClick={async()=>{setBusy(true);try{const membership=await getMyWorkspace(session.user.id);setWorkspaceId(membership?.workspace_id||null);setMembershipPending(membership?.membership_status==='pending');}catch(reason){setError(reason instanceof Error?reason.message:'No pudimos revisar tu solicitud.')}finally{setBusy(false)}}} disabled={busy}>{busy?'Revisando…':'Ya me aceptaron, entrar'}</button><Status error={error}/><button className="auth-text-button" onClick={()=>supabase?.auth.signOut()}>Cerrar sesión</button></section></div>;
  if (session && workspaceId && profile) {
    return <WorkspaceApp
      workspaceId={workspaceId}
      userId={session.user.id}
      email={session.user.email || ''}
      profile={profile}
      onProfileUpdate={setProfile}
      onSignOut={() => supabase?.auth.signOut()}
    />;
  }
  if (session) return <div className="auth-page"><section className="auth-card"><Brand/><span className="eyebrow">ESPACIO DEL EQUIPO</span><h1>Bienvenido, {profile?.full_name || session.user.user_metadata.full_name || 'equipo'}</h1><p>Elige cómo empezar. Si alguien ya creó el espacio, pídele su código de invitación.</p><form onSubmit={createTeam}><label className="field"><span>Nombre del equipo</span><input required minLength={2} value={workspaceName} onChange={e=>setWorkspaceName(e.target.value)} placeholder="Ej. Equipo de adoración"/></label><button className="primary full" disabled={busy}><ArrowRight size={16}/> Crear espacio compartido</button></form><div className="auth-divider"><span>O</span></div><form onSubmit={enterTeam}><label className="field"><span>Código de invitación</span><input required value={inviteCode} onChange={e=>setInviteCode(e.target.value.toUpperCase())} placeholder="Pide el código al líder del equipo"/></label><button className="secondary full" disabled={busy}>Unirme al equipo</button></form><Status error={error}/><button className="auth-text-button" onClick={()=>supabase?.auth.signOut()}>Cerrar sesión</button></section></div>;

  return <div className="auth-page"><section className="auth-card"><Brand/><span className="eyebrow">{mode === 'signup' ? 'CREA TU CUENTA' : 'QUÉ BUENO VERTE'}</span><h1>{mode === 'signup' ? 'Tu equipo, en un solo lugar' : 'Inicia sesión'}</h1><p>{mode === 'signup' ? 'Crea tu cuenta y completa tu perfil para guardar los datos de tu equipo en la nube.' : 'Entra para continuar en el espacio compartido de tu equipo.'}</p>
    <form onSubmit={submitAuth}>
      {mode === 'signup' && <>
        <label className="field"><span>Nombre completo</span><input required autoComplete="name" value={name} onChange={e=>setName(e.target.value)} placeholder="Tu nombre"/></label>
          <div className="form-grid auth-profile-grid"><label className="field"><span>Fecha de nacimiento <small>(privada)</small></span><input required type="date" max={latestBirthday} autoComplete="bday" value={birthDate} onChange={e=>setBirthDate(e.target.value)}/></label></div>
      </>}
      <label className="field"><span>Correo electrónico</span><input required type="email" autoComplete="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="nombre@correo.com"/></label>
      <label className="field"><span>Contraseña</span><span className="password-input-control"><input required type={passwordVisible?'text':'password'} minLength={8} autoComplete={mode === 'signup'?'new-password':'current-password'} value={password} onChange={e=>setPassword(e.target.value)} placeholder="Al menos 8 caracteres"/><button type="button" className="password-visibility" aria-label={passwordVisible?'Ocultar contraseña':'Mostrar contraseña'} aria-pressed={passwordVisible} onClick={()=>setPasswordVisible(value=>!value)}>{passwordVisible?<EyeOff size={18}/>:<Eye size={18}/>}</button></span></label>
      <button className="primary full" disabled={busy}>{busy?'Un momento…':mode==='signup'?'Crear cuenta':'Entrar'}</button>
    </form>
    {mode==='login'&&<button className="auth-text-button" onClick={()=>void resetPassword()}>Olvidé mi contraseña</button>}
    <Status error={error} message={message}/>
    <div className="auth-switch">{mode==='signup'?'¿Ya tienes cuenta?':'¿Aún no tienes cuenta?'} <button onClick={()=>{setMode(mode==='signup'?'login':'signup');setError('');setMessage('');}}>{mode==='signup'?'Inicia sesión':'Crear cuenta'}</button></div>
    <small className="privacy-note"><ShieldCheck size={14}/> Tu fecha de nacimiento solo la podrás ver tú.</small>
  </section></div>;
}

function Brand(){return <div className="auth-brand"><span className="brand-mark">U</span><div><b>UNARA</b><small>Un equipo. Un propósito.</small></div></div>}
function readErrorMessage(reason: unknown, fallback: string) {
  if (reason instanceof Error && reason.message) return reason.message;
  if (reason && typeof reason === 'object' && 'message' in reason && typeof reason.message === 'string') return reason.message;
  if (typeof reason === 'string' && reason.trim()) return reason;
  return fallback;
}
function Status({error,message}:{error?:string;message?:string}){return <>{error&&<div role="alert" className="auth-status error-status">{error}</div>}{message&&<div role="status" className="auth-status">{message}</div>}</>}
function MessageScreen({children}:{children:string}){return <div className="auth-page"><section className="auth-card"><Brand/><p>{children}</p></section></div>}
function SetupNeeded(){return <MessageScreen>Falta conectar el almacenamiento seguro de UNARA. La pantalla de registro aparecerá cuando la configuración esté lista.</MessageScreen>}
function readSaved<T>(key:string,fallback:T):T{try{const value=localStorage.getItem(key);return value?JSON.parse(value):fallback;}catch{return fallback;}}
