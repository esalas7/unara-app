type MemberOption = {
  id: string;
  name: string;
  team_functions: string[];
  other_function: string;
};

export default function MeetingFunctionAssignmentsEditor({
  members,
  selected,
  onChange,
}: {
  members: MemberOption[];
  selected: Record<string, string[]>;
  onChange: (memberId: string, functions: string[]) => void;
}) {
  const activeMembers = members;

  return <section className="form-card meeting-function-assignment">
    <span className="eyebrow">ASIGNACIÓN PARA ESTA REUNIÓN</span>
    <h3>Funciones de cada integrante</h3>
    <p>Elige una o varias funciones registradas en el perfil. Esta selección solo corresponde a esta reunión.</p>
    {!activeMembers.length
      ? <p>No hay integrantes activos en el equipo.</p>
      : <div className="meeting-function-members">{activeMembers.map(member => {
        const options = Array.from(new Set(member.team_functions || []));
        return <article className="meeting-function-member" key={member.id}>
          <b>{member.name}</b>
          {options.length
            ? <fieldset className="field">
                <legend>Funciones disponibles</legend>
                <div className="tag-options">{options.map(fn => {
                  const label = fn === 'Otro' && member.other_function ? `Otro: ${member.other_function}` : fn;
                  const checked = (selected[member.id] || []).includes(fn);
                  return <label className="tag-option" key={fn}>
                    <input type="checkbox" checked={checked} onChange={event => {
                      const current = selected[member.id] || [];
                      onChange(member.id, event.target.checked
                        ? [...current, fn]
                        : current.filter(value => value !== fn));
                    }}/>
                    {label}
                  </label>;
                })}</div>
              </fieldset>
            : <small className="meeting-no-functions">Esta persona no tiene funciones disponibles en su perfil.</small>}
        </article>;
      })}</div>}
  </section>;
}
