-- Ontdubbeling, rente- en bronlandcontrole (19-11-2026), migraties ontdubbeling_herhaling, top_signalen en ontdubbeling_rechten.
-- Deze definities VERVANGEN die van voeg_items_toe, import_edition, wissel_top, week_kandidaten en import_week in functions.sql.
--
-- Gebruik:
--   eerder_nieuws(datum, dagen)   dag- en feedrun: nieuws dat al gepubliceerd is (herhalingen voorkomen)
--   herhaling_check(datum)        topberichten die lijken op nieuws van de 7 dagen ervoor
--   top_signalen(datum, soort)    controle-run: herhaling, rentewijziging of buitenlandse bron in de top (dag of week)
--   norm_url(url)                 links gelijkmaken (www, hoofdletters, dubbele slash, utm, slash aan het eind)
--   bron_land(url)                NL / EU / BUITENLAND
--   is_rente_wijziging(tekst)     tariefwijziging of rente-overzicht

-- Ontdubbeling en herhalingscontrole (19-11-2026)
-- 1. pg_trgm voor tekstvergelijking (controle-run)
-- 2. norm_url: links gelijkmaken voor ontdubbeling (https/www, hoofdletters, dubbele slashes, slash aan het eind, utm/fbclid/gclid, #anker)
-- 3. eerder_nieuws: compacte lijst van eerder gepubliceerd nieuws voor dag- en feedrun
-- 4. herhaling_check: topberichten die sterk lijken op nieuws van de afgelopen dagen (controle-run)
-- 5. voeg_items_toe, import_edition, wissel_top, week_kandidaten, import_week: vergelijken op norm_url;
--    import_edition slaat links over die al in een eerdere dagedite stonden;
--    week_kandidaten sluit berichten uit die al in de vorige weekeditie stonden en geeft die editie mee.

create extension if not exists pg_trgm with schema extensions;

create or replace function public.norm_url(u text)
 returns text
 language sql
 immutable
 set search_path to 'public'
as $function$
  select case when u is null or btrim(u) = '' then null else
    rtrim(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(
                regexp_replace(lower(btrim(u)), '^https?://(www\.)?', ''),
              '#.*$', ''),
            '([?&])(utm_[a-z_]+|fbclid|gclid|mc_cid|mc_eid)=[^&]*', '\1', 'g'),
          '/{2,}', '/', 'g'),
        '\?&+', '?', 'g'),
      '&{2,}', '&', 'g'),
    '/?&')
  end
$function$;

create or replace function public.eerder_nieuws(p_datum date, p_dagen int default 8)
 returns jsonb
 language sql
 stable
 set search_path to 'public'
as $function$
  -- Nieuws dat al gepubliceerd is: dag- en weekedities van p_datum - p_dagen t/m de dag ervoor,
  -- plus de feedberichten die vandaag (p_datum) al zijn toegevoegd. Eén regel per link (dag gaat voor week).
  -- Vorm per regel: [datum, soort, sectie, categorie, tekst, link]
  select coalesce(jsonb_agg(jsonb_build_array(x.datum, x.soort, x.sectie, x.categorie, x.tekst, x.bron_url)
                            order by x.datum desc, x.sectie, x.categorie), '[]'::jsonb)
  from (
    select distinct on (coalesce(public.norm_url(i.bron_url), 'id:' || i.id::text))
           e.datum, e.soort, i.sectie, i.categorie,
           left(coalesce(i.kop || ': ', '') || i.zin, 160) as tekst, i.bron_url
    from items i join editions e on e.id = i.edition_id
    where (e.datum >= p_datum - p_dagen and e.datum < p_datum)
       or (e.soort = 'dag' and e.datum = p_datum and i.herkomst = 'feed')
    order by coalesce(public.norm_url(i.bron_url), 'id:' || i.id::text), (e.soort = 'dag') desc, e.datum
  ) x
$function$;

create or replace function public.herhaling_check(p_datum date, p_dagen int default 7, p_drempel numeric default 0.3)
 returns jsonb
 language sql
 stable
 set search_path to 'public', 'extensions'
as $function$
  -- Topberichten van de dagedite p_datum die dezelfde link hebben als, of sterk lijken op,
  -- een bericht uit de dagedities van de p_dagen dagen ervoor.
  select coalesce(jsonb_agg(jsonb_build_object(
           'top_positie', t.positie, 'top', left(coalesce(t.kop || ': ', '') || t.zin, 120),
           'eerder_datum', oe.datum, 'eerder', left(coalesce(o.kop || ': ', '') || o.zin, 120),
           'gelijkenis', round(similarity(lower(coalesce(t.kop, '') || ' ' || t.zin), lower(coalesce(o.kop, '') || ' ' || o.zin))::numeric, 2),
           'zelfde_link', public.norm_url(t.bron_url) = public.norm_url(o.bron_url))
         order by t.positie, oe.datum desc), '[]'::jsonb)
  from items t
  join editions te on te.id = t.edition_id and te.soort = 'dag' and te.datum = p_datum
  join items o on true
  join editions oe on oe.id = o.edition_id and oe.soort = 'dag'
                  and oe.datum between p_datum - p_dagen and p_datum - 1
  where t.sectie = 'top'
    and (public.norm_url(t.bron_url) = public.norm_url(o.bron_url)
         or similarity(lower(coalesce(t.kop, '') || ' ' || t.zin), lower(coalesce(o.kop, '') || ' ' || o.zin)) >= p_drempel)
$function$;

create or replace function public.voeg_items_toe(p jsonb)
 returns jsonb
 language plpgsql
 set search_path to 'public'
as $function$
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
    u := nullif(btrim(i->>'bron_url'),'');
    if u is null or u !~ '^https?://' then over := over + 1; continue; end if;
    -- bekende link (ook in een andere schrijfwijze) in de afgelopen 21 dagen of al in deze editie
    if exists (select 1 from items x where public.norm_url(x.bron_url) = public.norm_url(u)
               and (x.nieuws_datum >= d - 21 or x.edition_id = eid)) then over := over + 1; continue; end if;
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

create or replace function public.import_edition(p jsonb)
 returns uuid
 language plpgsql
 set search_path to 'public'
as $function$
declare
  e jsonb := p->'edition'; k jsonb := p->'kerncijfers'; eid uuid; t jsonb;
  d date := (p->'edition'->>'datum')::date;
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
  where not exists (select 1 from items f where f.edition_id = eid and f.bron_url is not null
                    and public.norm_url(f.bron_url) = public.norm_url(i->>'bron_url'))
    -- link stond al in een eerdere dagedite (afgelopen 21 dagen): niet opnieuw opnemen
    and not exists (select 1 from items o join editions oe on oe.id = o.edition_id
                    where oe.soort = 'dag' and oe.id <> eid and oe.datum between d - 21 and d - 1
                      and o.bron_url is not null and public.norm_url(o.bron_url) = public.norm_url(i->>'bron_url'))
  on conflict (edition_id, item_key) do nothing;

  -- kiest de dagrun als top een bericht dat de feedrun al heeft, dan wordt het feedbericht zelf de top
  for t in select * from jsonb_array_elements(coalesce(p->'items','[]')) i where i->>'sectie'='top' loop
    update items set sectie='top', positie=coalesce((t->>'positie')::int,0), kop=t->>'kop', waarom=t->>'waarom'
     where edition_id=eid and herkomst='feed' and public.norm_url(bron_url)=public.norm_url(t->>'bron_url') and sectie<>'top';
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

create or replace function public.wissel_top(p jsonb)
 returns jsonb
 language plpgsql
 set search_path to 'public'
as $function$
declare
  d date := (p->>'datum')::date; eid uuid; w jsonb; n int := 0; aan int := 0; fout int := 0;
  nieuw items%rowtype; oud items%rowtype; npos int; up int; bezet int;
begin
  select id into eid from editions where soort='dag' and datum=d;
  if eid is null then return jsonb_build_object('gewisseld',0,'aangevuld',0,'fout','geen editie'); end if;
  for w in select * from jsonb_array_elements(coalesce(p->'wissels','[]')) loop
    up := (w->>'uit_positie')::int;
    nieuw := null; oud := null;
    select * into nieuw from items where edition_id=eid and public.norm_url(bron_url)=public.norm_url(w->>'bron_url') and herkomst='feed' and sectie<>'top' limit 1;
    if nieuw.id is null or up is null or up<1 or up>3 then fout := fout+1; continue; end if;
    select * into oud from items where edition_id=eid and sectie='top' and positie=up and herkomst<>'feed' limit 1;
    if oud.id is null then
      -- geen te vervangen top-bericht: aanvullen als de positie vrij is
      select count(*) into bezet from items where edition_id=eid and sectie='top' and positie=up;
      if bezet>0 then fout := fout+1; continue; end if;
      update items set sectie='top', positie=up, kop=w->>'kop', waarom=w->>'waarom' where id=nieuw.id;
      aan := aan+1; continue;
    end if;
    select coalesce(max(positie),0)+1 into npos from items where edition_id=eid and sectie=public.sectie_van_categorie(oud.categorie);
    update items set sectie=public.sectie_van_categorie(oud.categorie), positie=npos, kop=null, waarom=null where id=oud.id;
    update items set sectie='top', positie=oud.positie, kop=w->>'kop', waarom=w->>'waarom' where id=nieuw.id;
    n := n+1;
  end loop;
  return jsonb_build_object('gewisseld',n,'aangevuld',aan,'mislukt',fout);
end $function$;

create or replace function public.week_kandidaten(p_van date, p_tot date)
 returns jsonb
 language sql
 stable
 set search_path to 'public'
as $function$
  with ed as (
    select id, datum from editions where soort = 'dag' and datum between p_van and p_tot
  ),
  vw as (
    -- de vorige weekeditie (vóór deze week)
    select id, datum from editions where soort = 'week' and datum < p_van order by datum desc limit 1
  ),
  vw_items as (
    select i.* from items i join vw on vw.id = i.edition_id
  ),
  it as (
    select i.id, e.datum as dag, i.sectie, i.categorie, i.positie, i.kop, i.zin, i.waarom, i.impact,
           i.labels, i.bron_naam, i.bron_url,
           row_number() over (
             partition by coalesce(public.norm_url(i.bron_url), 'id:' || i.id::text)
             order by (i.sectie = 'top') desc, e.datum, i.id
           ) as rn
    from items i join ed e on e.id = i.edition_id
    -- berichten die al in het vorige weekoverzicht stonden, tellen niet opnieuw mee
    where not exists (select 1 from vw_items v where v.bron_url is not null
                      and public.norm_url(v.bron_url) = public.norm_url(i.bron_url))
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
    ), '[]'::jsonb),
    'vorige_week', coalesce((
      select jsonb_agg(jsonb_build_array(v.sectie, v.categorie, left(coalesce(v.kop || ': ', '') || v.zin, 160))
                       order by (v.sectie = 'top') desc, v.positie)
      from vw_items v
    ), '[]'::jsonb)
  );
$function$;

create or replace function public.import_week(p jsonb)
 returns jsonb
 language plpgsql
 set search_path to 'public'
as $function$
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
  -- links die al in een eerdere weekeditie (afgelopen 14 dagen) stonden, worden overgeslagen
  insert into items (edition_id, sectie, categorie, positie, kop, zin, waarom, impact, labels, bron_naam, bron_url)
  select eid, x.j->>'sectie', x.j->>'categorie', coalesce((x.j->>'positie')::int, 100 + x.ord::int),
         x.j->>'kop', x.j->>'zin', x.j->>'waarom', x.j->>'impact',
         coalesce(array(select jsonb_array_elements_text(coalesce(x.j->'labels','[]'::jsonb))), '{}'),
         x.j->>'bron_naam', x.j->>'bron_url'
  from jsonb_array_elements(coalesce(p->'extra_items','[]'::jsonb)) with ordinality as x(j, ord)
  where not exists (select 1 from items o join editions oe on oe.id = o.edition_id
                    where oe.soort = 'week' and oe.datum < d and oe.datum >= d - 14
                      and o.bron_url is not null and public.norm_url(o.bron_url) = public.norm_url(x.j->>'bron_url'))
  on conflict (edition_id, item_key) do nothing;

  select count(*) into n_items from items where edition_id = eid;
  select count(*) into n_top from items where edition_id = eid and sectie = 'top';
  select count(*) into kc from kerncijfers where datum = d;

  return jsonb_build_object('edition_id', eid, 'items', n_items, 'top', n_top, 'kerncijfers', kc);
end $function$;

-- Signalen voor de controle-run (migratie top_signalen, 19-11-2026)
create or replace function public.is_rente_wijziging(t text)
 returns boolean
 language sql
 immutable
 set search_path to 'public'
as $function$
  -- tariefwijziging van een verstrekker of rente-overzicht (geen ECB-besluit; dat wordt op categorie uitgesloten)
  select coalesce(t, '') ~* '(verlaag|verhoog|verlaging|verhoging)[a-z]*[^.;]{0,50}?(rente|tarie)|(rente|tarie)[a-z]*[^.;]{0,15}?(omlaag|omhoog|verlaag|verhoog|verlaging|verhoging)|gemiddelde\s+(hypotheek)?rente|rentestand'
$function$;

create or replace function public.bron_land(u text)
 returns text
 language sql
 immutable
 set search_path to 'public'
as $function$
  select case
    when u is null then null
    when split_part(regexp_replace(lower(btrim(u)), '^https?://(www\.)?', ''), '/', 1)
         ~ '(\.nl|^(.*\.)?(rabobank|ing|abnamro|nn-group|nn|aegon|achmea|asrnl|triodos|quion|ohpen|stater|conclusion|devolksbank|nibc|florius|munt|hdn)\.com|^(.*\.)?blinqx\.tech)$' then 'NL'
    when split_part(regexp_replace(lower(btrim(u)), '^https?://(www\.)?', ''), '/', 1)
         ~ '(europa\.eu|^(.*\.)?(bis|fsb)\.org)$' then 'EU'
    else 'BUITENLAND' end
$function$;

create or replace function public.top_signalen(p_datum date, p_soort text default 'dag')
 returns jsonb
 language sql
 stable
 set search_path to 'public', 'extensions'
as $function$
  -- Signalen bij de top van een dag- of weekeditie: herhaling van eerder nieuws, rentewijziging of buitenlandse bron.
  with ed as (select id from editions where soort = p_soort and datum = p_datum),
  top as (select i.* from items i join ed on ed.id = i.edition_id where i.sectie = 'top'),
  eerder as (
    select oe.datum, o.kop, o.zin, o.bron_url
    from items o join editions oe on oe.id = o.edition_id
    where (p_soort = 'dag' and oe.soort = 'dag' and oe.datum between p_datum - 7 and p_datum - 1)
       or (p_soort = 'week' and oe.id = (select id from editions where soort = 'week' and datum < p_datum order by datum desc limit 1))
  ),
  sig as (
    select t.positie, 'herhaling' as signaal,
           'lijkt op ' || to_char(e.datum, 'DD-MM') || ': ' || left(coalesce(e.kop || ': ', '') || e.zin, 90) as detail
    from top t join lateral (
      select e.* from eerder e
      where public.norm_url(e.bron_url) = public.norm_url(t.bron_url)
         or similarity(lower(coalesce(t.kop, '') || ' ' || t.zin), lower(coalesce(e.kop, '') || ' ' || e.zin)) >= 0.3
      order by similarity(lower(coalesce(t.kop, '') || ' ' || t.zin), lower(coalesce(e.kop, '') || ' ' || e.zin)) desc
      limit 1) e on true
    union all
    select t.positie, 'rente', left(coalesce(t.kop || ': ', '') || t.zin, 90)
    from top t where t.categorie <> 'ECB' and public.is_rente_wijziging(coalesce(t.kop, '') || ' ' || t.zin)
    union all
    select t.positie, 'buitenland', split_part(regexp_replace(lower(t.bron_url), '^https?://(www\.)?', ''), '/', 1)
    from top t where public.bron_land(t.bron_url) = 'BUITENLAND'
  )
  select coalesce(jsonb_agg(jsonb_build_object('positie', positie, 'signaal', signaal, 'detail', detail) order by positie, signaal), '[]'::jsonb)
  from sig
$function$;

-- Rechten (migratie ontdubbeling_rechten): niet aanroepbaar vanuit de browser
revoke execute on function public.norm_url(text), public.bron_land(text), public.is_rente_wijziging(text),
  public.eerder_nieuws(date, int), public.herhaling_check(date, int, numeric), public.top_signalen(date, text),
  public.voeg_items_toe(jsonb), public.wissel_top(jsonb)
  from public, anon, authenticated;
