-- Feeds ophalen in de database zelf, zonder AI (sinds 23-11-2026)
-- feeds_ophalen() haalt elk uur (pg_cron, minuut 50) alle actieve rss-bronnen op met de http-extensie,
-- leest de items met xpath en zet nieuwe items in feed_ruw. Items zonder trefwoord (bij bronnen met
-- filter_modus 'zoekwoorden') en items waarvan de link al in een editie staat, worden meteen als
-- verwerkt gemarkeerd. De feedrun (06:55) leest alleen nog de onverwerkte items via feed_nieuw()
-- en legt na beoordeling vast welke items hij heeft verwerkt via feed_verwerkt(), dat ook de run logt.

create extension if not exists http with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.feed_ruw (
  id bigint generated always as identity primary key,
  bron_id bigint not null references public.bronnen(id),
  link text not null,
  link_norm text not null,
  titel text,
  beschrijving text,
  gepubliceerd timestamptz,
  opgehaald_at timestamptz not null default now(),
  trefwoord boolean not null default true,
  verwerkt_at timestamptz,
  uitkomst text,
  unique (bron_id, link_norm)
);
create index if not exists feed_ruw_open on public.feed_ruw (gepubliceerd) where verwerkt_at is null;
alter table public.feed_ruw enable row level security;
drop policy if exists "ingelogd leest feed_ruw" on public.feed_ruw;
create policy "ingelogd leest feed_ruw" on public.feed_ruw for select to authenticated using (true);

create table if not exists public.feed_runs (
  id bigint generated always as identity primary key,
  datum date not null,
  aangeboden int not null default 0,
  opgenomen int not null default 0,
  opmerking text,
  created_at timestamptz not null default now()
);
alter table public.feed_runs enable row level security;
drop policy if exists "ingelogd leest feed_runs" on public.feed_runs;
create policy "ingelogd leest feed_runs" on public.feed_runs for select to authenticated using (true);

-- Tekst uit een RSS-veld: CDATA eraf, entiteiten omzetten, HTML-tags weg, witruimte samenvoegen
create or replace function public.xml_tekst(t text)
 returns text language plpgsql immutable set search_path to 'public'
as $f$
declare s text := coalesce(t,'');
begin
  s := regexp_replace(s, '^\s*<!\[CDATA\[(.*)\]\]>\s*$', '\1', 's');
  for i in 1..2 loop
    s := replace(replace(replace(replace(replace(replace(s,'&lt;','<'),'&gt;','>'),'&quot;','"'),'&#39;',''''),'&apos;',''''),'&nbsp;',' ');
    s := replace(s,'&amp;','&');
  end loop;
  s := regexp_replace(s, '<[^>]*>', ' ', 'g');
  s := regexp_replace(s, '&#(\d+);', ' ', 'g');
  s := btrim(regexp_replace(s, '\s+', ' ', 'g'));
  return nullif(s,'');
end $f$;

-- Datum uit een RSS-veld (RFC 822, ook met Nederlandse dag- en maandnamen); null als het niet lukt
create or replace function public.rss_datum(t text)
 returns timestamptz language plpgsql stable set search_path to 'public'
as $f$
declare s text := btrim(coalesce(t,''));
begin
  if s = '' then return null; end if;
  begin return s::timestamptz; exception when others then null; end;
  s := regexp_replace(s, '^[a-zA-Z]{2,3}\.?,\s*', '');
  s := regexp_replace(s, '\m(jan|feb|mrt|apr|mei|jun|jul|aug|sep|okt|nov|dec)\.?', '\1', 'gi');
  s := replace(replace(replace(replace(lower(s),'mrt','mar'),'mei','may'),'okt','oct'),'utc','+00');
  begin return s::timestamptz; exception when others then return null; end;
end $f$;

create or replace function public.feed_trefwoord(t text)
 returns boolean language sql immutable set search_path to 'public'
as $f$
  select
    coalesce(t,'') ~* '(hypothe|woning|\mhuis\M|\mhuizen\M|koopwoning|nationale hypotheek garantie|loan-to-value|leennorm|aflossingsvrij|mortgage|residential real estate|housing|real estate|risicogewicht|risk weight|output floor|kapitaaleis|capital requirement|macroprudential|countercyclical buffer|borrower-based|hypothecair|consumer credit|consumentenkrediet|swaprente|rentebesluit|key ecb interest rates|monetary policy decision)'
    or coalesce(t,'') ~ '(\mNHG\M|\mLTV\M|\mCRR\M|\mBasel\M|\mFiDA\M|\mDORA\M|\mAI Act\M)'
    or ((coalesce(t,'') ~* '(artificial intelligence|kunstmatige intelligentie|generatieve ai|ai-agent)' or coalesce(t,'') ~ '\mAI\M')
        and coalesce(t,'') ~* '(bank|verzeker|hypothe|krediet|financi|fintech|adviseur)')
    or (coalesce(t,'') ~ '\mWwft\M' and coalesce(t,'') ~* '(bank|krediet)')
$f$;

-- Sinds 27-11-2026: berichten over gebeurtenissen die de ECB-rente kunnen raken.
-- A: wissel in de top van ECB of DNB (functie en wissel in dezelfde zin)
-- B: rentestap of renteverwachting van de ECB
-- D: inflatiecijfer eurozone (met percentage)
-- Gewone toespraken en interviews van ECB-bestuurders vallen er bewust buiten.
create or replace function public.ecb_rente_trefwoord(t text)
returns boolean language plpgsql immutable set search_path to 'public' as $f$
declare
  e text := '\m(ecb|europese centrale bank|european central bank|dnb|de nederlandsche bank)\M';
  f text := '\m(president|presidente|voorzitter|vicepresident|vice-president|hoofdeconoom|chief economist|directielid|directie|executive board)\M';
  r text;
  c text := '(opvolg|benoem|voorgedragen|voordracht|kandida|genomineerd|nominat|appoint|successor|succeed|aftreden|\mstapt\M[^.]{0,25}\mop\M|\mtreedt\M[^.]{0,25}\maf\M|vervroegd|vertrekt|\mvertrek\M|steps? down|resign|nieuwe (ecb-)?president|new president|future president|wordt (de )?nieuwe)';
begin
  t := coalesce(t, '');
  r := '(ecb-(president|presidente|voorzitter|vicepresident|vice-president|directie|directielid|hoofdeconoom|top)|dnb-president|lagarde|'
       || e || '[^.]{0,50}' || f || '|' || f || '[^.]{0,30}' || e || ')';
  -- A. topwissel
  if t ~* (r || '[^.]{0,100}' || c) or t ~* (c || '[^.]{0,100}' || r) or t ~* (e || '[^.]{0,80}' || c || '[^.]{0,60}' || f) then
    return true;
  end if;
  -- B. rentestap of renteverwachting
  if t ~* '(renteverlag|renteverhog|renteknip|rentestap|rentepauze|depositorente|beleidsrente|renteverwachting|rentepad|rate cuts?\M|rate hikes?|rate rises?|rate increases?|interest rates? (unchanged|on hold)|deposit (facility )?rate|policy rate|rate path|rate expectations|(verhoogt|verlaagt|verhogen|verlagen|houdt|laat) de rente|rente (ongewijzigd|onveranderd|gelijk))'
     and t ~* '(\mECB\M|ecb-|europese centrale bank|european central bank|lagarde|eurozone|eurogebied|euro area)' then
    return true;
  end if;
  -- D. inflatiecijfer eurozone
  if t ~* '(inflatie|inflation|\mHICP\M)[^.]{0,80}[0-9]+([,.][0-9]+)? ?(%|procent|percent)'
     and t ~* '(eurozone|eurogebied|euro area|eurolanden|\mECB\M)' then
    return true;
  end if;
  return false;
end $f$;

create or replace function public.feeds_ophalen()
 returns jsonb language plpgsql set search_path to 'public', 'extensions'
as $f$
declare
  b record; r extensions.http_response; x xml; it xml;
  n_items int; n_nieuw int; tot jsonb := '[]'::jsonb; lnk text; ttl text; ds text; dt timestamptz; tw boolean;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  for b in select * from bronnen where actief and type = 'rss' order by id loop
    begin
      r := extensions.http(('GET', b.feed_url,
             array[extensions.http_header('User-Agent','Mozilla/5.0 (compatible; Hypotheekmarkt-feedlezer/1.0)')],
             null, null)::extensions.http_request);
      if r.status <> 200 then raise exception 'HTTP %', r.status; end if;
      x := xmlparse(document regexp_replace(r.content, '^\s*<\?xml[^>]*\?>', ''));
      n_items := 0; n_nieuw := 0;
      foreach it in array xpath('/rss/channel/item', x) loop
        n_items := n_items + 1;
        lnk := btrim(public.xml_tekst((xpath('/item/link/text()', it))[1]::text));
        if lnk is null or lnk !~ '^https?://' then
          lnk := btrim(public.xml_tekst((xpath('/item/guid/text()', it))[1]::text));
        end if;
        if lnk is null or lnk !~ '^https?://' then continue; end if;
        dt := public.rss_datum(public.xml_tekst((xpath('/item/pubDate/text()', it))[1]::text));
        if dt is not null and dt < now() - interval '30 days' then continue; end if;
        -- sinds 24-11: een publicatietijd in de toekomst (Banken.nl dateert berichten vooruit) wordt het ophaalmoment
        if dt > now() then dt := now(); end if;
        ttl := public.xml_tekst((xpath('/item/title/text()', it))[1]::text);
        ds := left(public.xml_tekst((xpath('/item/description/text()', it))[1]::text), 1000);
        tw := b.filter_modus = 'alles' or public.feed_trefwoord(coalesce(ttl,'') || ' ' || coalesce(ds,''))
              or (b.instantie = 'ECB' and coalesce(ttl,'') ~* 'monetary policy decision')
              -- sinds 27-11: ECB-topwissels, rentestappen en inflatie eurozone
              or public.ecb_rente_trefwoord(coalesce(ttl,'') || '. ' || coalesce(ds,''));
        insert into feed_ruw (bron_id, link, link_norm, titel, beschrijving, gepubliceerd, trefwoord, verwerkt_at, uitkomst)
        values (b.id, lnk, public.norm_url(lnk), ttl, ds, dt, tw,
                case when tw then null else now() end, case when tw then null else 'geen trefwoord' end)
        on conflict (bron_id, link_norm) do nothing;
        if found then n_nieuw := n_nieuw + 1; end if;
      end loop;
      if n_items = 0 then raise exception 'geen items in de feed'; end if;
      update bronnen set laatste_ok = now(), laatste_fout = null, laatste_aantal = n_items, geverifieerd_op = current_date where id = b.id;
      tot := tot || jsonb_build_object('bron', b.naam, 'items', n_items, 'nieuw', n_nieuw);
    exception when others then
      update bronnen set laatste_fout = left('Ophalen ' || to_char(now() at time zone 'Europe/Amsterdam','DD-MM HH24:MI') || ': ' || sqlerrm, 150) where id = b.id;
      tot := tot || jsonb_build_object('bron', b.naam, 'fout', left(sqlerrm, 150));
    end;
  end loop;
  -- items waarvan de link al in een editie staat, hoeven niet meer beoordeeld te worden
  update feed_ruw f set verwerkt_at = now(), uitkomst = 'al gepubliceerd'
   where f.verwerkt_at is null
     and exists (select 1 from items i where i.bron_url is not null and public.norm_url(i.bron_url) = f.link_norm);
  return tot;
end $f$;

-- Onverwerkte items voor de feedrun. p_van/p_tot: periode van publicatie (items zonder datum tellen mee
-- als ze in de periode zijn opgehaald). p_ook_verwerkt: ook al verwerkte items (bij een override).
create or replace function public.feed_nieuw(p_van timestamptz, p_tot timestamptz, p_ook_verwerkt boolean default false)
 returns jsonb language sql stable set search_path to 'public'
as $f$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id, 'bron', b.naam, 'instantie', b.instantie, 'sectie', b.sectie, 'categorie', b.categorie,
      'labels', b.labels, 'titel', f.titel, 'beschrijving', left(f.beschrijving, 400), 'link', f.link,
      'gepubliceerd', to_char(coalesce(f.gepubliceerd, f.opgehaald_at) at time zone 'Europe/Amsterdam', 'YYYY-MM-DD HH24:MI'),
      'datum_onzeker', f.gepubliceerd is null)
    order by b.id, coalesce(f.gepubliceerd, f.opgehaald_at)), '[]'::jsonb)
  from feed_ruw f join bronnen b on b.id = f.bron_id
  where f.trefwoord
    and (p_ook_verwerkt or f.verwerkt_at is null)
    and coalesce(f.gepubliceerd, f.opgehaald_at) >= p_van
    and coalesce(f.gepubliceerd, f.opgehaald_at) <= p_tot
$f$;

-- Legt vast welke items de feedrun heeft beoordeeld en logt de run.
-- Invoer: {"datum":"JJJJ-MM-DD","verwerkt":[id,...],"opgenomen":[id,...],"opmerking":"..."}
create or replace function public.feed_verwerkt(p jsonb)
 returns jsonb language plpgsql set search_path to 'public'
as $f$
declare v bigint[]; o bigint[]; n int;
begin
  v := array(select (jsonb_array_elements_text(coalesce(p->'verwerkt','[]')))::bigint);
  o := array(select (jsonb_array_elements_text(coalesce(p->'opgenomen','[]')))::bigint);
  update feed_ruw set verwerkt_at = now(),
         uitkomst = case when id = any(o) then 'opgenomen ' || (p->>'datum') else 'beoordeeld, niet opgenomen' end
   where (id = any(v) or id = any(o)) and verwerkt_at is null;
  get diagnostics n = row_count;
  insert into feed_runs (datum, aangeboden, opgenomen, opmerking)
  values ((p->>'datum')::date, coalesce(array_length(v,1),0) + coalesce(array_length(o,1),0) - coalesce((select count(*) from unnest(o) x where x = any(v)),0),
          coalesce(array_length(o,1),0), left(p->>'opmerking', 300));
  return jsonb_build_object('gemarkeerd', n);
end $f$;

revoke execute on function public.feeds_ophalen() from anon, authenticated;
revoke execute on function public.feed_verwerkt(jsonb) from anon, authenticated;

-- Elk uur op minuut 50 (UTC); de run van 05:50 UTC (06:50 in de winter) is net vóór de feedrun van 06:55.
select cron.unschedule(jobid) from cron.job where jobname = 'feeds_ophalen';
select cron.schedule('feeds_ophalen', '50 * * * *', 'select public.feeds_ophalen()');

-- Eenmalig op 24-11-2026: vooruit gedateerde items teruggezet naar hun ophaalmoment:
-- update public.feed_ruw set gepubliceerd = opgehaald_at where gepubliceerd > opgehaald_at;

-- Eenmalig bij de start (23-11-2026): items van vóór de laatste geslaagde feedrun (19-11 06:58) als verwerkt gemarkeerd:
-- update public.feed_ruw set verwerkt_at = now(), uitkomst = 'voor start (al door feedrun beoordeeld)'
--  where verwerkt_at is null and gepubliceerd < '2026-11-19 06:58:00+01';
