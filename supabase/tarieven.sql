-- Tarieven opslaan en vergelijken (sinds 23-11-2026)
-- De dagrun (opdracht D) leest elke ochtend de Moneywise-tabellen (5, 10 en 20 jaar NHG, 10 jaar 100% LTV)
-- en de tariefkaarten van Argenta en Vista, en geeft die met tarieven_opslaan() aan de database.
-- De database bepaalt zelf de rentewijzigingen per verstrekker (laagste reguliere tarief per pagina,
-- vergeleken met de vorige stand) en de watchlist voor Argenta en Vista.

create table if not exists public.tarieven (
  datum date not null,
  bron text not null,            -- 'moneywise', 'argenta', 'vista'
  pagina text not null,          -- 'nhg_5', 'nhg_10', 'nhg_20', 'ltv100_10'
  peil date not null,            -- standdatum (Moneywise) of ingangsdatum van de tariefkaart
  aanbieder text not null,
  product text not null default '',
  tarief numeric(5,2) not null,
  primary key (datum, bron, pagina, aanbieder, product)
);
alter table public.tarieven enable row level security;
drop policy if exists "ingelogd leest tarieven" on public.tarieven;
create policy "ingelogd leest tarieven" on public.tarieven for select to authenticated using (true);

create or replace function public.korte_naam(a text)
 returns text language sql immutable set search_path to 'public'
as $f$ select case when x ~ '^[A-Z]{4,}$' then initcap(x) else x end from (select regexp_replace(btrim(a), '\s+(Hypotheken|Bank)$', '', 'i') as x) s $f$;

-- Laagste reguliere tarief per aanbieder voor één stand (groene en energielabelproducten tellen niet mee)
create or replace function public.tarief_laagste(p_datum date, p_bron text, p_pagina text)
 returns table (aanbieder text, tarief numeric, peil date)
 language sql stable set search_path to 'public'
as $f$
  select t.aanbieder, min(t.tarief), max(t.peil) from tarieven t
  where t.datum = p_datum and t.bron = p_bron and t.pagina = p_pagina
    and t.product !~* '(groen|energielabel|duurza)'
  group by t.aanbieder
$f$;

-- Wijzigingen per verstrekker op p_datum ten opzichte van de vorige stand met een oudere peildatum.
-- Vorm: [{"verstrekker":"Obvion","richting":"down","tekst":"NHG 10j −0,05; 100% LTV 10j −0,05","datum":"24/11"}]
create or replace function public.tarief_wijzigingen(p_datum date, p_bron text default 'moneywise')
 returns jsonb language sql stable set search_path to 'public'
as $f$
  with pag as (
    select distinct t.pagina, max(t.peil) over (partition by t.pagina) as peil_nu from tarieven t
    where t.datum = p_datum and t.bron = p_bron
  ), vorig as (
    select p.pagina, p.peil_nu,
      (select t.datum from tarieven t where t.bron = p_bron and t.pagina = p.pagina and t.datum < p_datum
        order by t.peil desc, t.datum desc limit 1) as datum_vorig
    from pag p
  ), verschil as (
    select v.pagina, v.peil_nu, n.aanbieder, n.tarief - o.tarief as delta
    from vorig v
    cross join lateral public.tarief_laagste(p_datum, p_bron, v.pagina) n
    join lateral public.tarief_laagste(v.datum_vorig, p_bron, v.pagina) o on o.aanbieder = n.aanbieder
    where v.datum_vorig is not null and v.peil_nu > o.peil and n.tarief <> o.tarief
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'verstrekker', x.naam,
      'richting', case when x.neer and not x.op then 'down' when x.op and not x.neer then 'up' else 'mix' end,
      'tekst', x.tekst, 'datum', x.datum) order by x.naam), '[]'::jsonb)
  from (
    select public.korte_naam(aanbieder) as naam,
      bool_or(delta < 0) as neer, bool_or(delta > 0) as op,
      string_agg(case pagina when 'nhg_5' then 'NHG 5j' when 'nhg_10' then 'NHG 10j' when 'nhg_20' then 'NHG 20j'
                             when 'ltv100_10' then '100% LTV 10j' else pagina end
                 || ' ' || case when delta > 0 then '+' else '−' end || replace(to_char(abs(delta), 'FM0.00'), '.', ','),
                 '; ' order by pagina) as tekst,
      to_char(max(peil_nu), 'DD/MM') as datum
    from verschil group by public.korte_naam(aanbieder)
  ) x
$f$;

-- Watchlist Argenta en Vista uit hun eigen tariefkaart (bron 'argenta' / 'vista'), met Moneywise als terugval.
-- Vorm zoals editions.watch: [{"naam":"Argenta","tekst":"...","richting":"down|up|flat|mix|null","per":"20/11","bron":[..]}]
create or replace function public.watch_tarieven(p_datum date)
 returns jsonb language plpgsql stable set search_path to 'public'
as $f$
declare
  w text; uit jsonb := '[]'::jsonb; bronnaam text; url text;
  peil_nu date; peil_vorig date; d_vorig date; nhg numeric; ltv numeric; nhg_o numeric; ltv_o numeric;
  delta_txt text; richting text; tekst text;
begin
  foreach w in array array['argenta','vista'] loop
    bronnaam := case w when 'argenta' then 'Argenta' else 'Vista' end;
    url := case w when 'argenta' then 'https://www.argenta.nl/hypotheek-argenta/hypotheekrente-overzicht'
                  else 'https://www.vistahypotheken.nl/actuele-hypotheekrente' end;
    select max(peil) into peil_nu from tarieven where datum = p_datum and bron = w;
    if peil_nu is null then
      uit := uit || jsonb_build_object('naam', bronnaam, 'tekst', 'Geen tariefkaart uitgelezen vandaag.', 'richting', null, 'per', null, 'bron', null);
      continue;
    end if;
    select min(tarief) filter (where pagina = 'nhg_10'), min(tarief) filter (where pagina = 'ltv100_10')
      into nhg, ltv from tarieven where datum = p_datum and bron = w;
    select t.datum, t.peil into d_vorig, peil_vorig from tarieven t
      where t.bron = w and t.datum < p_datum and t.peil < peil_nu order by t.peil desc, t.datum desc limit 1;
    richting := null; delta_txt := '';
    if d_vorig is not null then
      select min(tarief) filter (where pagina = 'nhg_10'), min(tarief) filter (where pagina = 'ltv100_10')
        into nhg_o, ltv_o from tarieven where datum = d_vorig and bron = w;
      richting := case
        when coalesce(nhg - nhg_o, 0) = 0 and coalesce(ltv - ltv_o, 0) = 0 then 'flat'
        when coalesce(nhg - nhg_o, 0) <= 0 and coalesce(ltv - ltv_o, 0) <= 0 then 'down'
        when coalesce(nhg - nhg_o, 0) >= 0 and coalesce(ltv - ltv_o, 0) >= 0 then 'up'
        else 'mix' end;
      delta_txt := ' (t.o.v. de kaart van ' || to_char(peil_vorig, 'DD/MM') || ': NHG '
        || case when nhg is null or nhg_o is null then 'n.b.' else (case when nhg >= nhg_o then '+' else '−' end) || replace(to_char(abs(nhg - nhg_o),'FM0.00'),'.',',') end
        || ', 100% LTV '
        || case when ltv is null or ltv_o is null then 'n.b.' else (case when ltv >= ltv_o then '+' else '−' end) || replace(to_char(abs(ltv - ltv_o),'FM0.00'),'.',',') end
        || ')';
    end if;
    tekst := 'Tariefkaart per ' || to_char(peil_nu, 'DD/MM') || ': 10 jaar vast NHG '
      || coalesce(replace(to_char(nhg,'FM0.00'),'.',',') || '%', 'n.b.')
      || ', 100% LTV ' || coalesce(replace(to_char(ltv,'FM0.00'),'.',',') || '%', 'n.b.') || delta_txt || '.';
    if peil_nu < p_datum - 3 then
      tekst := tekst || ' Geen nieuwe tariefkaart in de afgelopen dagen.';
    end if;
    uit := uit || jsonb_build_object('naam', bronnaam, 'tekst', tekst,
      'richting', case when peil_nu >= p_datum - 3 then richting else null end,
      'per', to_char(peil_nu, 'DD/MM'), 'bron', jsonb_build_array(bronnaam, url));
  end loop;
  return uit;
end $f$;

-- Opslaan en direct de uitkomst teruggeven.
-- Invoer: {"datum":"JJJJ-MM-DD","paginas":[{"bron":"moneywise","pagina":"nhg_10","peil":"JJJJ-MM-DD",
--          "regels":[["Lloyds Bank","Hypotheek (1)",4.15], ...]}, ...]}
-- Uitvoer: {"opgeslagen":N,"rente_wijzigingen":[...],"watch":[...],"eerste_stand":true|false}
create or replace function public.tarieven_opslaan(p jsonb)
 returns jsonb language plpgsql set search_path to 'public'
as $f$
declare d date := (p->>'datum')::date; pg jsonb; r jsonb; n int := 0; eerste boolean;
begin
  for pg in select * from jsonb_array_elements(coalesce(p->'paginas','[]')) loop
    if coalesce(pg->>'bron','') !~ '^(moneywise|argenta|vista)$' or coalesce(pg->>'pagina','') !~ '^(nhg_5|nhg_10|nhg_20|ltv100_10)$'
       or (pg->>'peil') is null then continue; end if;
    delete from tarieven where datum = d and bron = pg->>'bron' and pagina = pg->>'pagina';
    for r in select * from jsonb_array_elements(coalesce(pg->'regels','[]')) loop
      begin
        insert into tarieven (datum, bron, pagina, peil, aanbieder, product, tarief)
        values (d, pg->>'bron', pg->>'pagina', (pg->>'peil')::date, btrim(r->>0), coalesce(nullif(btrim(r->>1),''),''),
                replace(r->>2, ',', '.')::numeric)
        on conflict (datum, bron, pagina, aanbieder, product) do update set tarief = greatest(tarieven.tarief, excluded.tarief);
        n := n + 1;
      exception when others then null;
      end;
    end loop;
  end loop;
  select not exists (select 1 from tarieven where bron = 'moneywise' and datum < d) into eerste;
  return jsonb_build_object('opgeslagen', n, 'eerste_stand', eerste,
    'rente_wijzigingen', public.tarief_wijzigingen(d, 'moneywise'), 'watch', public.watch_tarieven(d));
end $f$;

revoke execute on function public.tarieven_opslaan(jsonb) from anon, authenticated;

-- Eenmalig: op 23-11-2026 is de stand van die dag (4 Moneywise-pagina's, tariefkaarten Argenta 20/11 en Vista 18/11)
-- als startpunt opgeslagen, zodat de dagrun van 24-11 al wijzigingen kan bepalen.
