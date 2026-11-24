-- Hulpfuncties voor de geplande runs (sinds 24-11-2026)
--
-- 1. run_override: een handmatige start met een andere datum of eindtijd.
--    Extra tekst bij een handmatige start komt pas binnen nadat de run zijn opdracht al heeft uitgevoerd,
--    waardoor de run twee keer draaide. Daarom zet je de override nu klaar in de database en start je
--    de taak zonder tekst:
--      insert into public.run_override (taak, datum, einde) values ('feedrun', '2026-11-24', '07:00');
--    De run vraagt in stap 1 public.run_override('<taak>') op. Die geeft de laatst klaargezette, nog niet
--    gebruikte override van de afgelopen 30 minuten terug ({"datum":..,"einde":..} of null) en markeert hem
--    als gebruikt, zodat hij maar één keer geldt.
-- 2. run_signalen: signalen voor de controle om 09:30 (feedrun zonder WebFetch, dagrun zonder eigen
--    berichten, tarieven die ontbreken of verouderd zijn).

create table if not exists public.run_override (
  id bigint generated always as identity primary key,
  taak text not null check (taak in ('feedrun','dagrun')),
  datum date not null,
  einde time,
  aangemaakt timestamptz not null default now(),
  gebruikt_at timestamptz
);
alter table public.run_override enable row level security;

create or replace function public.run_override(p_taak text)
 returns jsonb language plpgsql set search_path to 'public'
as $f$
declare r public.run_override;
begin
  select * into r from run_override
   where taak = p_taak and gebruikt_at is null and aangemaakt >= now() - interval '30 minutes'
   order by aangemaakt desc limit 1;
  -- alle openstaande overrides van deze taak vervallen, ook oudere
  update run_override set gebruikt_at = now() where taak = p_taak and gebruikt_at is null;
  if r.id is null then return null; end if;
  return jsonb_build_object('datum', to_char(r.datum, 'YYYY-MM-DD'), 'einde', to_char(r.einde, 'HH24:MI'));
end $f$;

-- Signalen voor de controle. Vorm: ["feedrun: ...", "dagrun: ...", "tarieven: ..."]; [] als alles klopt.
create or replace function public.run_signalen(p_datum date)
 returns jsonb language plpgsql stable set search_path to 'public'
as $f$
declare s text[] := '{}'; e uuid; n int; rec record; mx date; pl date;
begin
  -- feedrun: WebFetch geweigerd of niet beschikbaar
  for rec in select opmerking from feed_runs
              where datum = p_datum and opmerking ~* '(niet beschikbaar|geweigerd|niet toegestaan)' order by id loop
    s := s || ('feedrun: ' || left(rec.opmerking, 140));
  end loop;
  -- dagrun: berichten uit het eigen onderzoek (niet uit de feeds)
  select id into e from editions where soort = 'dag' and datum = p_datum;
  if e is not null then
    select count(*) into n from items where edition_id = e and coalesce(herkomst, '') <> 'feed';
    if n = 0 then s := s || 'dagrun: 0 eigen berichten (alle berichten komen uit de feeds)'::text; end if;
  end if;
  -- tarieven: elke pagina hoort vandaag opgeslagen te zijn; Moneywise mag niet ouder zijn dan 3 dagen
  for rec in select * from (values ('moneywise','nhg_5'),('moneywise','nhg_10'),('moneywise','nhg_20'),('moneywise','ltv100_10'),
                                   ('argenta','nhg_10'),('argenta','ltv100_10'),('vista','nhg_10'),('vista','ltv100_10')) v(bron, pagina) loop
    select max(peil) into pl from tarieven t where t.datum = p_datum and t.bron = rec.bron and t.pagina = rec.pagina;
    if pl is null then
      select max(peil) into mx from tarieven t where t.bron = rec.bron and t.pagina = rec.pagina;
      s := s || format('tarieven: %s %s niet opgeslagen (niet gelezen of verouderde pagina; laatste stand %s)',
                       rec.bron, rec.pagina, coalesce(to_char(mx, 'DD-MM'), 'geen'));
    elsif rec.bron = 'moneywise' and pl < p_datum - 3 then
      s := s || format('tarieven: moneywise %s stand %s is ouder dan 3 dagen', rec.pagina, to_char(pl, 'DD-MM'));
    end if;
  end loop;
  return to_jsonb(s);
end $f$;

revoke execute on function public.run_override(text) from anon, authenticated;
revoke execute on function public.run_signalen(date) from anon, authenticated;
