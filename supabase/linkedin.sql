-- LinkedIn-radar: volglijst (bedrijven en bestuurders) en gevonden LinkedIn-posts.
-- Toegepast als migraties `linkedin_radar` en `linkedin_radar_snippetdatum` op 2026-11-12. Wijzigingen aan de database lopen via een
-- migratie in Supabase; leg ze daarna ook hier vast.
--
-- Hoe posts binnenkomen: LinkedIn blokkeert geautomatiseerd ophalen (robots.txt) en de gebruikersvoorwaarden
-- verbieden scrapen. De geplande taak `linkedinrun` (runs/linkedinrun.md) zoekt daarom via zoekmachines naar
-- openbare posts van de volglijst. Elke LinkedIn-postlink bevat een activity-ID waarin het plaatsingstijdstip
-- zit (bits 63..22 = milliseconden sinds 1970), dus de datum is exact zonder de pagina te openen.
-- De samenvatting (kern) is altijd in eigen woorden; de volledige posttekst wordt niet opgeslagen.

-- ---------- tabellen

create table public.linkedin_accounts (
  id bigint generated always as identity primary key,
  soort text not null check (soort in ('bedrijf','persoon')),
  naam text not null,
  bedrijf text not null,                -- groep voor filters en zoekopdrachten, bv. 'Vista'
  functie text,
  slug text,                            -- LinkedIn-vanity: /in/<slug>, /company/<slug>, /posts/<slug>_...
  linkedin_url text generated always as (
    case when slug is null then null
         when soort = 'persoon' then 'https://www.linkedin.com/in/' || slug
         else 'https://www.linkedin.com/company/' || slug end) stored,
  zoeknaam text,                        -- zoekterm voor de run (bedrijven), bv. 'Vista Hypotheken'
  prioriteit int not null default 2 check (prioriteit between 1 and 3),   -- 1 = belangrijkst
  actief boolean not null default true,
  functie_bron text,                    -- link waar de functie is vastgesteld
  functie_peil date,                    -- datum van die bron
  laatste_post date,
  laatste_check timestamptz,
  opmerking text,                       -- o.a. signalen van de run (functiewissel)
  created_at timestamptz not null default now(),
  constraint linkedin_accounts_naam_key unique (soort, naam, bedrijf)
);
create unique index linkedin_accounts_slug_key on public.linkedin_accounts (lower(slug)) where slug is not null;

create table public.linkedin_posts (
  id bigint generated always as identity primary key,
  account_id bigint references public.linkedin_accounts(id) on delete set null,
  auteur text not null,
  bedrijf text,
  functie text,                         -- functie van de auteur toen de post werd gevonden
  post_url text not null,
  activity_id bigint,
  post_datum timestamptz not null,
  datum_bron text not null check (datum_bron in ('activity_id','snippet','artikel')),
  soort text not null default 'post' check (soort in ('post','repost','artikel','media')),
  kern text not null,                   -- één zin, eigen woorden
  waarom text,
  thema text,
  labels text[] not null default '{}',
  relevantie int not null default 2 check (relevantie between 1 and 3),  -- 3 = zeer relevant
  gevonden_via text not null default 'zoekmachine' check (gevonden_via in ('zoekmachine','media','handmatig')),
  bron_naam text,
  bron_url text,
  gevonden_op date not null default (now() at time zone 'Europe/Amsterdam')::date,
  created_at timestamptz not null default now()
);
-- (post_url, post_datum): een profiel- of bedrijfspagina kan meerdere posts met een exacte datePublished dragen
create unique index linkedin_posts_url_datum_key on public.linkedin_posts (post_url, post_datum);
create unique index linkedin_posts_activity_key on public.linkedin_posts (activity_id) where activity_id is not null;
create index linkedin_posts_datum_idx on public.linkedin_posts (post_datum desc);
create index linkedin_posts_gevonden_idx on public.linkedin_posts (gevonden_op);
create index linkedin_posts_bedrijf_idx on public.linkedin_posts (bedrijf);
create index linkedin_posts_account_idx on public.linkedin_posts (account_id);

create table public.linkedin_runs (
  id bigint generated always as identity primary key,
  datum date not null,
  zoekopdrachten int,
  kandidaten int,
  toegevoegd int not null default 0,
  overgeslagen int not null default 0,
  opmerking text,
  created_at timestamptz not null default now()
);
create index linkedin_runs_datum_idx on public.linkedin_runs (datum desc);

alter table public.linkedin_accounts enable row level security;
alter table public.linkedin_posts enable row level security;
alter table public.linkedin_runs enable row level security;
create policy "alleen ingelogd lezen" on public.linkedin_accounts for select to authenticated using (true);
create policy "alleen ingelogd lezen" on public.linkedin_posts for select to authenticated using (true);
create policy "alleen ingelogd lezen" on public.linkedin_runs for select to authenticated using (true);

-- ---------- hulpfuncties

-- Plaatsingstijdstip uit een LinkedIn activity-/ugcPost-/share-ID.
create or replace function public.linkedin_ts(aid bigint) returns timestamptz
 language sql immutable set search_path to 'public' as $fn$
  select case when aid is null then null else to_timestamp((aid >> 22) / 1000.0) end $fn$;

-- Activity-ID uit een postlink (linkedin.com/posts/..-activity-<id>-.., /feed/update/urn:li:activity:<id>, ugcPost, share).
create or replace function public.linkedin_aid(u text) returns bigint
 language sql immutable set search_path to 'public' as $fn$
  select nullif(substring(coalesce(u,'') from '(?:activity|ugcPost|share)(?:-|:|%3A|%3a)([0-9]{18,20})'), '')::bigint $fn$;

-- Kleinste activity-ID vanaf een datum (00:00 Europe/Amsterdam): handig om zoekresultaten snel te filteren.
create or replace function public.linkedin_min_aid(d date) returns bigint
 language sql immutable set search_path to 'public' as $fn$
  select (floor(extract(epoch from (d::timestamp at time zone 'Europe/Amsterdam')) * 1000)::bigint) << 22 $fn$;

-- Eén vorm per link: LinkedIn-links naar https://www.linkedin.com zonder querystring (trk=...) of anker.
create or replace function public.linkedin_norm_url(u text) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case
    when u ~* '^https?://([a-z0-9-]+\.)?linkedin\.com/'
      then 'https://www.linkedin.com' || regexp_replace(regexp_replace(u, '^https?://[^/]+', ''), '[?#].*$', '')
    else regexp_replace(btrim(u), '#.*$', '') end $fn$;

-- Volglijst voor de run: actieve accounts per bedrijf, de zoekperiode en de al bekende links.
create or replace function public.linkedin_volglijst(p_datum date, p_dagen int default 10) returns jsonb
 language sql stable set search_path to 'public' as $fn$
  select jsonb_build_object(
    'datum', p_datum,
    'sinds', p_datum - p_dagen,
    'min_activity_id', public.linkedin_min_aid(p_datum - p_dagen),
    'groepen', coalesce((
      select jsonb_agg(jsonb_build_object('bedrijf', b.bedrijf, 'prioriteit', b.prio, 'accounts', b.accounts) order by b.prio, b.bedrijf)
      from (
        select a.bedrijf, min(a.prioriteit) as prio,
               jsonb_agg(jsonb_build_object('id', a.id, 'soort', a.soort, 'naam', a.naam, 'functie', a.functie,
                                            'slug', a.slug, 'zoeknaam', a.zoeknaam, 'prioriteit', a.prioriteit)
                         order by a.soort, a.prioriteit, a.naam) as accounts
        from public.linkedin_accounts a where a.actief group by a.bedrijf
      ) b), '[]'::jsonb),
    'bekend', coalesce((select jsonb_agg(p.post_url order by p.post_datum desc)
                        from public.linkedin_posts p where p.post_datum >= (p_datum - 45)::timestamptz), '[]'::jsonb)
  ) $fn$;

-- Opslag door de run. Eén aanroep per run, ook zonder posts (dan wordt alleen de run gelogd).
-- p = {"datum":"JJJJ-MM-DD","sinds":"JJJJ-MM-DD"?,"zoekopdrachten":N,"kandidaten":N,"opmerking":"..",
--      "posts":[{"account_id":1?,"auteur":"..","bedrijf":".."?,"functie":".."?,"post_url":"https://..",
--                "post_datum":"JJJJ-MM-DD"? (alleen nodig zonder activity-ID),"soort":"post|repost|artikel|media",
--                "kern":"één zin","waarom":"..","thema":"..","labels":["Hypo"],"relevantie":1..3,
--                "gevonden_via":"zoekmachine|media|handmatig","bron_naam":".."?,"bron_url":".."?}],
--      "accounts":[{"id":1,"slug":"vanity"}],          -- ontbrekende LinkedIn-vanity aanvullen
--      "signalen":[{"id":1,"tekst":"mogelijk vertrokken bij ..."}]}
create or replace function public.linkedin_voeg_toe(p jsonb) returns jsonb
 language plpgsql set search_path to 'public' as $fn$
declare
  d date := coalesce((p->>'datum')::date, (now() at time zone 'Europe/Amsterdam')::date);
  sinds date := coalesce((p->>'sinds')::date, d - 14);
  x jsonb; u text; aid bigint; ts timestamptz; dbron text; acc linkedin_accounts; via text; srt text; pd text;
  nieuw int := 0; over int := 0; redenen jsonb := '[]'::jsonb; rid bigint; labs text[];
begin
  for x in select * from jsonb_array_elements(coalesce(p->'posts','[]'::jsonb)) loop
    u := public.linkedin_norm_url(nullif(btrim(x->>'post_url'),''));
    via := coalesce(nullif(x->>'gevonden_via',''), 'zoekmachine');
    srt := coalesce(nullif(x->>'soort',''), case when via = 'media' then 'media' else 'post' end);
    if u is null or u !~* '^https?://' then
      over := over + 1; redenen := redenen || jsonb_build_object('url', x->>'post_url', 'reden', 'geen geldige link'); continue;
    end if;
    if coalesce(btrim(x->>'kern'),'') = '' or coalesce(btrim(x->>'auteur'),'') = '' then
      over := over + 1; redenen := redenen || jsonb_build_object('url', u, 'reden', 'kern of auteur ontbreekt'); continue;
    end if;
    aid := public.linkedin_aid(u);
    ts := public.linkedin_ts(aid);
    if ts is not null and ts between timestamptz '2015-01-01' and now() + interval '1 day' then
      dbron := 'activity_id';
    else
      aid := null;
      pd := nullif(btrim(x->>'post_datum'),'');
      begin  -- datum (JJJJ-MM-DD, dan 12:00 NL-tijd) of exact tijdstip (datePublished)
        ts := case when pd is null then null
                   when pd ~ '^\d{4}-\d{2}-\d{2}$' then pd::date::timestamp at time zone 'Europe/Amsterdam' + interval '12 hours'
                   else pd::timestamptz end;
      exception when others then ts := null;
      end;
      dbron := case when via = 'media' then 'artikel' else 'snippet' end;
    end if;
    if ts is null then
      over := over + 1; redenen := redenen || jsonb_build_object('url', u, 'reden', 'datum niet vast te stellen'); continue;
    end if;
    if (ts at time zone 'Europe/Amsterdam')::date < sinds or ts > now() + interval '1 day' then
      over := over + 1; redenen := redenen || jsonb_build_object('url', u, 'reden', 'buiten periode (' || to_char(ts at time zone 'Europe/Amsterdam','DD-MM-YYYY') || ')'); continue;
    end if;
    if exists (select 1 from linkedin_posts q
               where (aid is not null and (q.activity_id = aid or q.post_url = u))
                  or (aid is null and q.post_url = u and (dbron = 'artikel' or abs(extract(epoch from q.post_datum - ts)) < 60))) then
      over := over + 1; redenen := redenen || jsonb_build_object('url', u, 'reden', 'al bekend'); continue;
    end if;
    acc := null;
    if nullif(x->>'account_id','') is not null then
      select * into acc from linkedin_accounts where id = (x->>'account_id')::bigint;
    end if;
    if acc.id is null then
      select * into acc from linkedin_accounts a where lower(a.naam) = lower(btrim(x->>'auteur')) order by a.soort desc limit 1;
    end if;
    labs := coalesce(array(select l.v from jsonb_array_elements_text(coalesce(x->'labels','[]'::jsonb)) as l(v) where l.v in ('Hypo','Digi','Board')), '{}');
    insert into linkedin_posts (account_id, auteur, bedrijf, functie, post_url, activity_id, post_datum, datum_bron, soort,
                                kern, waarom, thema, labels, relevantie, gevonden_via, bron_naam, bron_url, gevonden_op)
    values (acc.id, btrim(x->>'auteur'), coalesce(nullif(x->>'bedrijf',''), acc.bedrijf), coalesce(nullif(x->>'functie',''), acc.functie),
            u, aid, ts, dbron, srt, btrim(x->>'kern'), nullif(btrim(x->>'waarom'),''), nullif(x->>'thema',''), labs,
            least(3, greatest(1, coalesce((x->>'relevantie')::int, 2))), via, nullif(x->>'bron_naam',''),
            nullif(public.linkedin_norm_url(nullif(x->>'bron_url','')),''), d)
    on conflict do nothing;
    if found then
      nieuw := nieuw + 1;
      if acc.id is not null then
        update linkedin_accounts set laatste_post = greatest(coalesce(laatste_post, date '1970-01-01'), (ts at time zone 'Europe/Amsterdam')::date) where id = acc.id;
      end if;
    else
      over := over + 1; redenen := redenen || jsonb_build_object('url', u, 'reden', 'al bekend');
    end if;
  end loop;

  -- ontbrekende LinkedIn-vanity's aanvullen (alleen als er nog geen staat en hij nergens anders in gebruik is)
  update linkedin_accounts a set slug = lower(btrim(s->>'slug'))
    from jsonb_array_elements(coalesce(p->'accounts','[]'::jsonb)) s
   where a.id = (s->>'id')::bigint and a.slug is null and coalesce(s->>'slug','') ~ '^[A-Za-z0-9_-]{3,100}$'
     and not exists (select 1 from linkedin_accounts b where lower(b.slug) = lower(btrim(s->>'slug')));

  -- signalen (bijv. mogelijke functiewissel) bij het account bewaren; de gebruiker beslist
  update linkedin_accounts a set opmerking = left(to_char(d,'DD-MM-YYYY') || ': ' || btrim(s->>'tekst') || coalesce(' | ' || a.opmerking, ''), 1000)
    from jsonb_array_elements(coalesce(p->'signalen','[]'::jsonb)) s
   where a.id = (s->>'id')::bigint and coalesce(btrim(s->>'tekst'),'') <> '';

  update linkedin_accounts set laatste_check = now() where actief;

  insert into linkedin_runs (datum, zoekopdrachten, kandidaten, toegevoegd, overgeslagen, opmerking)
  values (d, nullif(p->>'zoekopdrachten','')::int, nullif(p->>'kandidaten','')::int, nieuw, over, nullif(left(p->>'opmerking', 500),''))
  returning id into rid;

  return jsonb_build_object('run', rid, 'toegevoegd', nieuw, 'overgeslagen', over, 'redenen', redenen);
end $fn$;

revoke all on function public.linkedin_voeg_toe(jsonb) from public, anon, authenticated;

-- Posts voor de weekmail en de weekweergave: geplaatst in de week (za t/m vr), plus posts die sinds de vorige
-- weekmail (vrijdag ~10:00) zijn gevonden maar eerder geplaatst zijn (laat = true). Zo komt elke post precies één
-- keer in een weekmail. Migratie `linkedin_week_laat_gevonden`. Uitvoerbaar voor ingelogde gebruikers (RLS geldt).
create or replace function public.linkedin_week(p_datum date)
returns table (id bigint, auteur text, functie text, bedrijf text, post_url text, post_datum timestamptz, datum_bron text,
               gevonden_via text, bron_naam text, kern text, waarom text, thema text, labels text[], relevantie int,
               gevonden_op date, laat boolean)
language sql stable set search_path to 'public' as $fn$
  with w as (
    select (p_datum - 6)::timestamp at time zone 'Europe/Amsterdam' as van,
           (p_datum + 1)::timestamp at time zone 'Europe/Amsterdam' as tot,
           (p_datum - 7)::timestamp at time zone 'Europe/Amsterdam' + interval '9 hours 55 minutes' as vorige_mail,
           p_datum::timestamp at time zone 'Europe/Amsterdam' + interval '9 hours 55 minutes' as deze_mail)
  select p.id, p.auteur, p.functie, p.bedrijf, p.post_url, p.post_datum, p.datum_bron, p.gevonden_via, p.bron_naam,
         p.kern, p.waarom, p.thema, p.labels, p.relevantie, p.gevonden_op, p.post_datum < w.van as laat
  from linkedin_posts p, w
  where p.relevantie >= 2
    and ((p.post_datum >= w.van and p.post_datum < w.tot)
      or (p.post_datum < w.van and p.created_at >= w.vorige_mail and p.created_at < w.deze_mail))
  order by p.relevantie desc, p.post_datum desc
  limit 10
$fn$;
revoke all on function public.linkedin_week(date) from public, anon;
grant execute on function public.linkedin_week(date) to authenticated;

revoke all on function public.linkedin_volglijst(date, int) from public, anon, authenticated;

-- ---------- volglijst: startversie (functies vastgesteld op 12-11-2026; bron per regel)
-- De volglijst is data en wordt in de database bijgehouden (bijv. op 12-11 al bijgewerkt: Sevdican naar Achmea IM,
-- Mons naar Conclusion Benelux, Thanabalasingam naar Yellowtail, Schuitemaker inactief, LinkedIn-vanity's aangevuld).
-- Gebruik onderstaande insert alleen bij herstel; de actuele stand staat in tabel linkedin_accounts.

insert into public.linkedin_accounts (soort, naam, bedrijf, functie, slug, zoeknaam, prioriteit, functie_bron, functie_peil, opmerking) values
-- bedrijfspagina's
('bedrijf','Achmea Bank','Achmea',null,null,'Achmea Bank',1,null,null,null),
('bedrijf','Syntrus Achmea Hypotheken','Achmea',null,null,'Syntrus Achmea Hypotheken',1,null,null,null),
('bedrijf','Achmea Mortgages','Achmea',null,null,'Achmea Mortgages',2,null,null,null),
('bedrijf','Achmea','Achmea',null,null,'Achmea',2,null,null,null),
('bedrijf','Argenta Nederland','Argenta',null,null,'Argenta hypotheken',1,null,null,null),
('bedrijf','Vista Hypotheken','Vista',null,'vistahypotheken','Vista Hypotheken',1,null,null,null),
('bedrijf','Stater','Stater',null,'stater','Stater hypotheken',1,null,null,null),
('bedrijf','Quion','Quion',null,null,'Quion hypotheken',1,null,null,null),
('bedrijf','Ohpen','Ohpen',null,null,'Ohpen',1,null,null,null),
('bedrijf','HDN','HDN',null,'vereniginghdn','HDN Hypotheken Data Netwerk',1,null,null,null),
('bedrijf','Yellowtail Conclusion','Yellowtail',null,null,'Yellowtail Conclusion',2,null,null,null),
('bedrijf','Davinci Conclusion','Davinci',null,null,'Davinci Conclusion',2,null,null,null),
('bedrijf','Conclusion','Conclusion',null,null,'Conclusion hypotheken',3,null,null,'Alleen hypotheekgerelateerd nieuws'),
('bedrijf','Blinqx','Blinqx',null,null,'Blinqx hypotheek',2,null,null,null),
('bedrijf','ROMEO','ROMEO',null,null,'ROMEO hypotheken',2,null,null,null),
('bedrijf','Oper Credits','Oper',null,null,'Oper Credits',2,null,null,null),
-- Achmea
('persoon','Bianca Tetteroo','Achmea','Voorzitter Raad van Bestuur Achmea',null,null,2,'https://news.achmea.nl/achmea-appoints-rogier-peters-member-of-the-executive-board-and-chief-risk-officer/','2026-04-14',null),
('persoon','Michel Lamie','Achmea','Vicevoorzitter Raad van Bestuur en CFO Achmea',null,null,3,'https://news.achmea.nl/achmea-appoints-rogier-peters-member-of-the-executive-board-and-chief-risk-officer/','2026-04-14',null),
('persoon','Daphne de Kluis','Achmea','Lid Raad van Bestuur Achmea',null,null,3,'https://news.achmea.nl/achmea-appoints-rogier-peters-member-of-the-executive-board-and-chief-risk-officer/','2026-04-14',null),
('persoon','Pierre Huurman','Achmea','Directievoorzitter (CEO) Achmea Bank','pierre-huurman-34775b14',null,1,'https://www.achmeabank.nl/en/news/achmea-bank-signs-agreement-with-nvvk-to-provide-swift-support-to-customers-with-debt-problems','2026-03-19',null),
('persoon','Arnoud Kuiper','Achmea','CFO Achmea Bank','arnoud-kuiper',null,1,'https://achmeabank.nl/en/about-us/managing-board','2026-03-13',null),
('persoon','Wendie Cornelissen','Achmea','Statutair directeur Achmea Bank (risk)',null,null,2,'https://achmeabank.nl/en/news/appointments-at-achmea-bank---arnoud-kuiper-and-wendie-cornelissen','2025-01-13',null),
('persoon','Hikmet Sevdican','Achmea','Directeur Hypotheken Syntrus Achmea',null,null,1,'https://www.banken.nl/nieuws/sector/benoemingen/product/hypotheek','2024-01-19','Functie uit januari 2024: actualiteit controleren'),
-- Argenta
('persoon','Sander Blommaert','Argenta','CEO Argenta Nederland',null,null,1,'https://www.banken.nl/nieuws/25420/argenta-nederland-benoemt-judith-jeuring-tot-directeur-sparen','2024-07-29','Laatste bevestiging juli 2024: actualiteit controleren'),
('persoon','Bruno Oudega','Argenta','Directeur Wonen Argenta Nederland',null,null,1,'https://www.banken.nl/nieuws/24795/argenta-nederland-benoemt-bruno-oudega-tot-directeur-wonen','2023-10-05',null),
('persoon','Peter Devlies','Argenta','CEO Argenta Bank- en Verzekeringsgroep',null,null,3,'https://www.argenta.eu/content/dam/argenta-eu-site/news-documents/2026/argenta-celebrates-70-year-anniversary-and-accelerates-strategic-growth-in-asset-management-and-insurance.pdf','2026-04-01',null),
-- Vista
('persoon','Merlyn van den Berg','Vista','CEO Vista Hypotheken','merlynvandenberg',null,1,'https://www.banken.nl/nieuws/26403/vista-passeert-grens-van-10-miljard-aan-verstrekte-hypotheken','2025-09-17',null),
('persoon','Stan Pijnenburg','Vista','CFRO Vista Hypotheken','stanpijnenburg',null,2,'https://www.linkedin.com/in/stanpijnenburg/','2025-09-05',null),
('persoon','Koen Ooms','Vista','Commercieel directeur Vista Hypotheken','koen-ooms-511a4b83',null,1,'https://www.banken.nl/nieuws/24386/vista-hypotheken-benoemt-koen-ooms-tot-commercieel-directeur','2023-03-02',null),
-- Stater
('persoon','Erwin Dreuning','Stater','CEO Stater','erwindreuning',null,1,'https://nl.marketscreener.com/insider/ERWIN-DREUNING-A2HDCB/','2026-11-12','LinkedIn-kop noemt beschikbaarheid voor commissariaten: functie in de gaten houden'),
('persoon','Mario Menheere','Stater','Managing Director Stater Nederland','mario-menheere-a58b334',null,2,'https://www.linkedin.com/in/mario-menheere-a58b334/','2026-11-12',null),
('persoon','Frank Schuitemaker','Stater','COO Stater',null,null,3,'https://be.marketscreener.com/insider/FRANK-SCHUITEMAKER-A2HDCK/','2026-11-12',null),
-- Quion
('persoon','Frank Schrijver','Quion','CEO Quion',null,null,1,'https://www.banken.nl/nieuws/26880/frank-schrijver-nieuwe-ceo-bij-quion','2026-02-27','Benoeming was onder voorbehoud van goedkeuring toezichthouder'),
-- Ohpen
('persoon','Matthijs Aler','Ohpen','CEO Ohpen',null,null,1,'https://www.owler.com/company/ohpen','2026-06-03',null),
('persoon','Jan-Lamber Voortman','Ohpen','COO Ohpen','jlvoortman',null,2,'https://nl.linkedin.com/in/jlvoortman','2026-06-12',null),
-- HDN
('persoon','Reinier van der Heijden','HDN','Directeur-bestuurder HDN',null,null,1,'https://www.banken.nl/nieuws/27101/jennifer-op-t-hoog-verlaat-hdn-voor-directeursfunctie-bij-asr','2026-05-18','Tweede bestuurszetel vacant sinds vertrek Jennifer op ''t Hoog (aug 2026)'),
-- Yellowtail / Davinci / Conclusion
('persoon','Matthijs Mons','Yellowtail','Managing Director Yellowtail Conclusion en directeur Conclusion Nederland',null,null,1,'https://theorg.com/org/yellowtail/org-chart/matthijs-mons','2026-11-12',null),
('persoon','Joost Zandvliet','Yellowtail','Director Mortgages & Loans Yellowtail Conclusion',null,null,2,'https://yellowtail.nl/en/news/joost-zandvliet-benoemd-tot-director-bij-yellowtail-conclusion/','2026-11-12',null),
('persoon','Maarten Tellegen','Yellowtail','Director Hypact Advisor (Yellowtail Conclusion)',null,null,3,'https://yellowtail.nl/en/news/advisors-who-embrace-ai-lead-the-mortgage-market/','2026-11-12',null),
('persoon','Bira Thanabalasingam','Davinci','Voorzitter managementteam Davinci Conclusion',null,null,2,'https://www.consultancy.nl/adviesbureaus/davinci','2023-05-19','Functie uit mei 2023: actualiteit controleren'),
-- Blinqx
('persoon','Ruud van der Kruk','Blinqx','CEO Blinqx',null,null,1,'https://blinqx.ai/en/news/blinqx-strengthens-management-team-to-accelerate-growth-ambitions-and-innovation','2026-11-12',null),
('persoon','Auke Dirkmaat','Blinqx','Managing Director Blinqx Insurance & Mortgage',null,null,1,'https://blinqx.ai/en/news/blinqx-strengthens-management-team-to-accelerate-growth-ambitions-and-innovation','2026-11-12',null),
-- ROMEO
('persoon','Paul van der Meijs','ROMEO','CEO ROMEO',null,null,2,'https://prospeo.io/c/romeo','2026-11-12','Zwakke bron (contactdatabase): functie controleren'),
-- Oper
('persoon','Geert Van Kerckhoven','Oper','CEO en medeoprichter Oper Credits','geertvankerckhoven',null,1,'https://www.opercredits.com/case-studies','2026-11-12',null);
