-- Functies in schema public van de Hypotheeknieuwsdatabase.
-- Gekopieerd uit de live database op 2026-11-06 (pg_get_functiondef).
-- Gebruikers: voeg_items_toe + wissel_top (feedrun), import_edition (dagrun),
-- week_kandidaten + import_week (weekrun). sectie_van_categorie en items_set_nieuws_datum zijn hulpfuncties.
-- Volgorde bij herstel: sectie_van_categorie, items_set_nieuws_datum, daarna de rest.

CREATE OR REPLACE FUNCTION public.sectie_van_categorie(c text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when c in ('ECB','DNB','AFM','EBA, Basel & Europa','Nederlands beleid & wetgeving','Kifid & rechtspraak','Wetgeving in procedure','Compliance & integriteit','Operationele weerbaarheid, data & AI') then 'toezicht' else 'nieuws' end $function$;

CREATE OR REPLACE FUNCTION public.items_set_nieuws_datum()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.nieuws_datum is null then
    select datum into new.nieuws_datum from public.editions where id = new.edition_id;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.import_edition(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  e jsonb := p->'edition'; k jsonb := p->'kerncijfers'; eid uuid; t jsonb;
begin
  insert into editions (soort, datum, periode, onderwerp, watch, rente_wijzigingen, vooruitzicht, duiding, agenda, vooruitblik, niet_gevonden, basis)
  values (e->>'soort', (e->>'datum')::date, e->>'periode', e->>'onderwerp',
    coalesce(e->'watch','[]'), coalesce(e->'rente_wijzigingen','[]'),
    nullif(e->'vooruitzicht','null'), coalesce(e->'duiding','[]'),
    coalesce(e->'agenda','[]'), coalesce(e->'vooruitblik','[]'),
    e->>'niet_gevonden', e->>'basis')
  on conflict (soort, datum) do update set
    periode = excluded.periode, onderwerp = excluded.onderwerp, watch = excluded.watch,
    rente_wijzigingen = excluded.rente_wijzigingen, vooruitzicht = excluded.vooruitzicht,
    duiding = excluded.duiding, agenda = excluded.agenda, vooruitblik = excluded.vooruitblik,
    niet_gevonden = excluded.niet_gevonden, basis = excluded.basis
  returning id into eid;

  update items set sectie = public.sectie_van_categorie(categorie), kop = null, waarom = null
   where edition_id = eid and herkomst = 'feed' and sectie = 'top';
  delete from items where edition_id = eid and herkomst <> 'feed';
  insert into items (edition_id, sectie, categorie, positie, kop, zin, waarom, impact, labels, bron_naam, bron_url)
  select eid, i->>'sectie', i->>'categorie', coalesce((i->>'positie')::int, 0), i->>'kop', i->>'zin',
         i->>'waarom', i->>'impact',
         coalesce(array(select jsonb_array_elements_text(coalesce(i->'labels','[]'))), '{}'),
         i->>'bron_naam', i->>'bron_url'
  from jsonb_array_elements(coalesce(p->'items','[]')) i
  where not exists (select 1 from items f where f.edition_id = eid and f.bron_url is not null and f.bron_url = i->>'bron_url')
  on conflict (edition_id, item_key) do nothing;

  -- kiest de dagrun als top een bericht dat de feedrun al heeft, dan wordt het feedbericht zelf de top
  for t in select * from jsonb_array_elements(coalesce(p->'items','[]')) i where i->>'sectie'='top' loop
    update items set sectie='top', positie=coalesce((t->>'positie')::int,0), kop=t->>'kop', waarom=t->>'waarom'
     where edition_id=eid and herkomst='feed' and bron_url=t->>'bron_url' and sectie<>'top';
  end loop;

  if k is not null and k <> 'null'::jsonb then
    insert into kerncijfers (datum, rente10_ltv100, rente_peil, swap10, swap_slot, marge_bp, top5_stand, top5_nhg, top5_ltv, curve, bronnoot)
    values ((k->>'datum')::date, (k->>'rente10_ltv100')::numeric, (k->>'rente_peil')::date,
            (k->>'swap10')::numeric, (k->>'swap_slot')::date, (k->>'marge_bp')::int,
            (k->>'top5_stand')::date, k->'top5_nhg', k->'top5_ltv', nullif(k->'curve','null'), k->>'bronnoot')
    on conflict (datum) do update set
      rente10_ltv100 = excluded.rente10_ltv100, rente_peil = excluded.rente_peil, swap10 = excluded.swap10,
      swap_slot = excluded.swap_slot, marge_bp = excluded.marge_bp, top5_stand = excluded.top5_stand,
      top5_nhg = excluded.top5_nhg, top5_ltv = excluded.top5_ltv, curve = excluded.curve, bronnoot = excluded.bronnoot;
  end if;
  return eid;
end $function$;

CREATE OR REPLACE FUNCTION public.voeg_items_toe(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  d date := (p->>'datum')::date;
  eid uuid;
  i jsonb;
  nieuw int := 0; over int := 0; stub boolean := false;
  pos int;
  u text;
begin
  select id into eid from editions where soort = 'dag' and datum = d;
  if eid is null then
    insert into editions (soort, datum, onderwerp) values ('dag', d, 'Hypotheekmarkt') returning id into eid;
    stub := true;
  end if;
  for i in select * from jsonb_array_elements(coalesce(p->'items','[]')) loop
    u := nullif(i->>'bron_url','');
    if u is null or u !~ '^https?://' then over := over + 1; continue; end if;
    if exists (select 1 from items x where x.bron_url = u and x.nieuws_datum >= d - 21) then over := over + 1; continue; end if;
    select coalesce(max(positie),0) + 1 into pos from items where edition_id = eid and sectie = i->>'sectie';
    insert into items (edition_id, sectie, categorie, positie, kop, zin, waarom, impact, labels, bron_naam, bron_url, herkomst)
    values (eid, i->>'sectie', i->>'categorie', pos, i->>'kop', i->>'zin', i->>'waarom', i->>'impact',
            coalesce(array(select jsonb_array_elements_text(coalesce(i->'labels','[]'))), '{}'),
            i->>'bron_naam', u, 'feed')
    on conflict (edition_id, item_key) do nothing;
    if found then nieuw := nieuw + 1; else over := over + 1; end if;
  end loop;
  return jsonb_build_object('editie', eid, 'toegevoegd', nieuw, 'overgeslagen', over, 'editie_aangemaakt', stub);
end $function$;

CREATE OR REPLACE FUNCTION public.wissel_top(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  d date := (p->>'datum')::date; eid uuid; w jsonb; n int := 0; fout int := 0;
  nieuw items%rowtype; oud items%rowtype; npos int;
begin
  select id into eid from editions where soort='dag' and datum=d;
  if eid is null then return jsonb_build_object('gewisseld',0,'fout','geen editie'); end if;
  for w in select * from jsonb_array_elements(coalesce(p->'wissels','[]')) loop
    select * into nieuw from items where edition_id=eid and bron_url=w->>'bron_url' and herkomst='feed' and sectie<>'top' limit 1;
    select * into oud from items where edition_id=eid and sectie='top' and positie=(w->>'uit_positie')::int and herkomst<>'feed' limit 1;
    if nieuw.id is null or oud.id is null then fout := fout+1; continue; end if;
    select coalesce(max(positie),0)+1 into npos from items where edition_id=eid and sectie=public.sectie_van_categorie(oud.categorie);
    update items set sectie=public.sectie_van_categorie(oud.categorie), positie=npos, kop=null, waarom=null where id=oud.id;
    update items set sectie='top', positie=oud.positie, kop=w->>'kop', waarom=w->>'waarom' where id=nieuw.id;
    n := n+1;
  end loop;
  return jsonb_build_object('gewisseld',n,'mislukt',fout);
end $function$;

CREATE OR REPLACE FUNCTION public.week_kandidaten(p_van date, p_tot date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with ed as (
    select id, datum from editions where soort = 'dag' and datum between p_van and p_tot
  ),
  it as (
    select i.id, e.datum as dag, i.sectie, i.categorie, i.positie, i.kop, i.zin, i.waarom, i.impact,
           i.labels, i.bron_naam, i.bron_url,
           row_number() over (
             partition by coalesce(i.bron_url, 'id:' || i.id::text)
             order by (i.sectie = 'top') desc, e.datum, i.id
           ) as rn
    from items i join ed e on e.id = i.edition_id
  )
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.dag, x.sectie, x.positie)
      from (select id, dag, sectie, categorie, positie, kop, zin, waarom, impact, labels, bron_naam, bron_url
            from it where rn = 1) x
    ), '[]'::jsonb),
    'edities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'datum', e2.datum, 'periode', e2.periode, 'watch', e2.watch,
        'rente_wijzigingen', e2.rente_wijzigingen, 'vooruitzicht', e2.vooruitzicht,
        'agenda', e2.agenda, 'niet_gevonden', e2.niet_gevonden) order by e2.datum)
      from editions e2 where e2.soort = 'dag' and e2.datum between p_van and p_tot
    ), '[]'::jsonb)
  );
$function$;

CREATE OR REPLACE FUNCTION public.import_week(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  e jsonb := coalesce(p->'edition', '{}'::jsonb);
  d date := (p->>'datum')::date;
  eid uuid;
  n_items int;
  n_top int;
  kc int;
  toez text[] := array['ECB','DNB','AFM','EBA, Basel & Europa','Nederlands beleid & wetgeving','Kifid & rechtspraak','Wetgeving in procedure','Compliance & integriteit','Operationele weerbaarheid, data & AI'];
  nws text[] := array['Geldverstrekkers & producten','Serviceproviders & keten','Adviesketens & intermediair','Digitalisering & data','Strategie & resultaten','Funding & kapitaalmarkt','Markt & onderzoek','Personalia'];
begin
  if d is null then raise exception 'datum ontbreekt'; end if;

  -- weekuitgave: duiding is bewust altijd leeg
  insert into editions (soort, datum, periode, onderwerp, watch, rente_wijzigingen, vooruitzicht, duiding, agenda, vooruitblik, niet_gevonden, basis)
  values ('week', d, p->>'periode', p->>'onderwerp',
          coalesce(e->'watch','[]'), coalesce(e->'rente_wijzigingen','[]'),
          nullif(e->'vooruitzicht','null'), '[]'::jsonb,
          coalesce(e->'agenda','[]'), coalesce(e->'vooruitblik','[]'),
          e->>'niet_gevonden', e->>'basis')
  on conflict (soort, datum) do update set
    periode = excluded.periode, onderwerp = excluded.onderwerp, watch = excluded.watch,
    rente_wijzigingen = excluded.rente_wijzigingen, vooruitzicht = excluded.vooruitzicht,
    duiding = '[]'::jsonb, agenda = excluded.agenda, vooruitblik = excluded.vooruitblik,
    niet_gevonden = excluded.niet_gevonden, basis = excluded.basis
  returning id into eid;

  delete from items where edition_id = eid;

  -- top: kopieer bestaande dag-items op id, met eigen kop en waarom
  insert into items (edition_id, sectie, categorie, positie, kop, zin, waarom, impact, labels, bron_naam, bron_url, nieuws_datum)
  select eid, 'top', s.categorie, t.ord::int, t.j->>'kop', s.zin, t.j->>'waarom', s.impact, s.labels, s.bron_naam, s.bron_url, s.nieuws_datum
  from jsonb_array_elements(coalesce(p->'top','[]'::jsonb)) with ordinality as t(j, ord)
  join items s on s.id = (t.j->>'id')::bigint
  on conflict (edition_id, item_key) do nothing;

  -- overige items: kopieer op id; items die in de dag 'top' stonden gaan terug naar hun eigen sectie
  insert into items (edition_id, sectie, categorie, positie, kop, zin, waarom, impact, labels, bron_naam, bron_url, nieuws_datum)
  select eid, k.nsec, k.categorie,
         row_number() over (partition by k.nsec order by coalesce(array_position(nws, k.categorie), array_position(toez, k.categorie), 99), k.id)::int,
         null, k.zin, null, k.impact, k.labels, k.bron_naam, k.bron_url, k.nieuws_datum
  from (
    select s.*,
           case when s.sectie = 'top' then
                  case when s.categorie = any(toez) then 'toezicht'
                       when s.categorie = any(nws) then 'nieuws'
                       else 'bedrijf' end
                else s.sectie end as nsec
    from items s
    where s.id in (select v::bigint from jsonb_array_elements_text(coalesce(p->'keep_ids','[]'::jsonb)) v)
      and s.id not in (select (j->>'id')::bigint from jsonb_array_elements(coalesce(p->'top','[]'::jsonb)) j)
  ) k
  on conflict (edition_id, item_key) do nothing;

  -- extra items die niet in de dagedities staan (zelfde vorm als bij import_edition); datum via trigger = weekdatum
  insert into items (edition_id, sectie, categorie, positie, kop, zin, waarom, impact, labels, bron_naam, bron_url)
  select eid, x.j->>'sectie', x.j->>'categorie', coalesce((x.j->>'positie')::int, 100 + x.ord::int),
         x.j->>'kop', x.j->>'zin', x.j->>'waarom', x.j->>'impact',
         coalesce(array(select jsonb_array_elements_text(coalesce(x.j->'labels','[]'::jsonb))), '{}'),
         x.j->>'bron_naam', x.j->>'bron_url'
  from jsonb_array_elements(coalesce(p->'extra_items','[]'::jsonb)) with ordinality as x(j, ord)
  on conflict (edition_id, item_key) do nothing;

  select count(*) into n_items from items where edition_id = eid;
  select count(*) into n_top from items where edition_id = eid and sectie = 'top';
  select count(*) into kc from kerncijfers where datum = d;

  return jsonb_build_object('edition_id', eid, 'items', n_items, 'top', n_top, 'kerncijfers', kc);
end $function$;
