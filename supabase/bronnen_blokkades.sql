-- Bronnen en blokkadelijst (sinds 23-11-2026)
-- 1. bronnen.ritme: 'dag' (elke feedrun) of 'week' (alleen op maandag, of als de laatste goede keer > 7 dagen geleden is)
-- 2. InFinance, Hypotheek Businessclub en Findinet lezen via hun RSS-feed in plaats van de homepage
-- 3. Nieuw: AFM (nieuws voor professionals) en NOS Economie; Consultancy.nl uit; Kifid wekelijks
-- 4. geblokkeerde_domeinen: sites waarvan artikelpagina's niet te openen zijn (robots, betaalmuur, rate limit).
--    Runs lezen de lijst vooraf via geblokkeerd() en slaan die domeinen over; ze melden nieuwe of
--    herhaalde blokkades via meld_blokkade(). Een domein dat 14 dagen niet is gemeld, valt vanzelf
--    van de lijst, zodat het daarna opnieuw wordt geprobeerd.

alter table public.bronnen add column if not exists ritme text not null default 'dag'
  check (ritme in ('dag','week'));

update public.bronnen set type='rss', feed_url='https://infinance.nl/feed/' where id=11;
update public.bronnen set type='rss', feed_url='https://hypotheekbusinessclub.nl/feed/' where id=13;
update public.bronnen set type='rss', feed_url='https://www.findinet.nl/feed/' where id=14;
update public.bronnen set actief=false where id=15;   -- Consultancy.nl: algemeen consultancynieuws
update public.bronnen set ritme='week' where id=9;    -- Kifid: pagina zonder datumlijst, kost zoekopdrachten

insert into public.bronnen (naam, instantie, feed_url, type, sectie, categorie, labels, filter_modus, ritme)
values
  ('AFM nieuws voor professionals', 'AFM', 'https://www.afm.nl/nl-nl/rss', 'rss', 'toezicht', 'AFM', '{Hypo,Board}', 'alles', 'dag'),
  ('NOS Economie', 'NOS', 'https://feeds.nos.nl/nosnieuwseconomie', 'rss', 'nieuws', null, '{Hypo,Board}', 'zoekwoorden', 'dag')
on conflict (feed_url) do nothing;

create table if not exists public.geblokkeerde_domeinen (
  domein text primary key,
  reden text not null,
  eerst_gezien date not null default current_date,
  laatst_gezien date not null default current_date,
  keer int not null default 1
);
alter table public.geblokkeerde_domeinen enable row level security;
drop policy if exists "ingelogd leest blokkades" on public.geblokkeerde_domeinen;
create policy "ingelogd leest blokkades" on public.geblokkeerde_domeinen for select to authenticated using (true);

create or replace function public.domein_van(u text)
 returns text language sql immutable set search_path to 'public'
as $f$
  select nullif(split_part(split_part(regexp_replace(lower(btrim(coalesce(u,''))), '^(https?://)?(www\.)?', ''), '/', 1), ':', 1), '')
$f$;

-- Actieve blokkades: gemeld in de afgelopen p_dagen dagen. Vorm: [{"domein":..,"reden":..,"sinds":..}]
create or replace function public.geblokkeerd(p_dagen int default 14)
 returns jsonb language sql stable set search_path to 'public'
as $f$
  select coalesce(jsonb_agg(jsonb_build_object('domein', domein, 'reden', reden, 'sinds', eerst_gezien) order by domein), '[]'::jsonb)
  from geblokkeerde_domeinen where laatst_gezien >= current_date - p_dagen
$f$;

-- Meldt blokkades. Invoer: [{"domein":"emerce.nl","reden":"robots"}] of {"blokkades":[...]}; domein mag ook een volledige URL zijn.
create or replace function public.meld_blokkade(p jsonb)
 returns jsonb language plpgsql set search_path to 'public'
as $f$
declare b jsonb; d text; n int := 0;
begin
  for b in select * from jsonb_array_elements(case when jsonb_typeof(p)='array' then p else coalesce(p->'blokkades','[]') end) loop
    d := public.domein_van(b->>'domein');
    if d is null or d !~ '^[a-z0-9.-]+\.[a-z]{2,}$' then continue; end if;
    insert into geblokkeerde_domeinen (domein, reden) values (d, left(coalesce(nullif(btrim(b->>'reden'),''),'onbekend'),120))
    on conflict (domein) do update set reden = excluded.reden, laatst_gezien = current_date,
      keer = geblokkeerde_domeinen.keer + case when geblokkeerde_domeinen.laatst_gezien < current_date then 1 else 0 end;
    n := n + 1;
  end loop;
  return jsonb_build_object('gemeld', n);
end $f$;

revoke execute on function public.meld_blokkade(jsonb) from anon, authenticated;

-- Startvulling uit de niet_gevonden-meldingen van november 2026
select public.meld_blokkade('[
 {"domein":"fd.nl","reden":"niet bereikbaar"},
 {"domein":"nu.nl","reden":"niet bereikbaar"},
 {"domein":"emerce.nl","reden":"artikelpagina geblokkeerd door browsercontrole"},
 {"domein":"globalcapital.com","reden":"betaalmuur, opvraag geblokkeerd"},
 {"domein":"pensioenpro.nl","reden":"robots-blokkade en betaalmuur"},
 {"domein":"stater.nl","reden":"nieuwspagina geblokkeerd door robots"},
 {"domein":"bloomberg.com","reden":"geblokkeerd voor robots"},
 {"domein":"vastgoedjournaal.nl","reden":"betaalmuur"},
 {"domein":"rd.nl","reden":"pagina geblokkeerd"},
 {"domein":"vastgoedbs.nl","reden":"artikel niet te openen"}
]'::jsonb);
