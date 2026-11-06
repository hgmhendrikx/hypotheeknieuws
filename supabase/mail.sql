-- Nieuwsbrief-export van het weekoverzicht (e-mail met volledige HTML in de body).
-- Gebruik: select public.week_mail('2026-11-06');
-- Resultaat: {"onderwerp":"...","html":"<!doctype html>...","tekst":"...","items":N}
-- De HTML is e-mailveilig: tabellen, inline CSS, geen JavaScript, geen externe CSS of afbeeldingen.
-- Dezelfde inhoud en volgorde als de weekpagina op de site.
-- Alleen uitvoerbaar met de service-/postgres-rol (geen toegang voor anon/authenticated).

create or replace function public.mail_esc(t text) returns text
 language sql immutable set search_path to 'public' as $fn$
  select replace(replace(replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;'),'''','&#39;') $fn$;

create or replace function public.mail_pc(x numeric) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case when x is null then 'n.b.' else replace(round(x,2)::text,'.',',') end $fn$;

create or replace function public.mail_dm(d date) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case when d is null then 'n.b.' else extract(day from d)::int || '/' || extract(month from d)::int end $fn$;

create or replace function public.mail_dl(n int) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case when n is null then 'vorige week n.b.'
              when n = 0 then '▬ gelijk t.o.v. vorige week'
              else case when n > 0 then '▲ ' else '▼ ' end || abs(n) || ' bp ' || case when n > 0 then 'hoger' else 'lager' end || ' t.o.v. vorige week' end $fn$;

create or replace function public.mail_pills(l jsonb) returns text
 language sql immutable set search_path to 'public' as $fn$
  select coalesce(string_agg(
    '<span style="background:' || case v when 'Hypo' then '#E0E7FF' when 'Digi' then '#E0F2FE' when 'Board' then '#FEF3C7' else '#E2E8F0' end
    || ';color:' || case v when 'Hypo' then '#3730A3' when 'Digi' then '#075985' when 'Board' then '#92400E' else '#334155' end
    || ';padding:1px 6px;border-radius:9px;font-size:11px;font-weight:bold">' || public.mail_esc(v) || '</span>', ' ' order by o), '')
  from jsonb_array_elements_text(case when jsonb_typeof(l) = 'array' then l else '[]'::jsonb end) with ordinality as t(v, o) $fn$;

create or replace function public.mail_src(naam text, url text) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case when coalesce(url,'') ~* '^https?://'
    then '<a href="' || public.mail_esc(url) || '" style="color:#4F46E5">' || public.mail_esc(coalesce(nullif(naam,''),'bron')) || '</a>'
    else '' end $fn$;

create or replace function public.mail_meta(parts text[]) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case when x = '' then '' else '<div style="font-size:12px;line-height:18px;color:#64748B;padding-top:4px">' || x || '</div>' end
  from (select coalesce(string_agg(p, ' · ' order by o) filter (where coalesce(p,'') <> ''), '') as x
        from unnest(parts) with ordinality as t(p, o)) s $fn$;

create or replace function public.mail_arrow(r text, per text) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case when r in ('down','up','flat','mix','?') then
    ' <span style="font-weight:bold;color:' || case r when 'down' then '#16A34A' when 'up' then '#DC2626' else '#64748B' end || '">'
    || case r when 'down' then '▼ gedaald' when 'up' then '▲ gestegen' when 'flat' then '▬ gelijk' when 'mix' then '▼▲ wisselend' else '? onzeker' end
    || case when coalesce(per,'') <> '' then ' per ' || public.mail_esc(per) else '' end || '</span>'
    else '' end $fn$;

-- head, lead, sub en meta zijn al HTML; tekst wordt hier geëscaped.
create or replace function public.mail_row(head text, lead text, tekst text, sub text, meta text) returns text
 language sql immutable set search_path to 'public' as $fn$
  select '<tr><td style="padding:10px 14px;border-top:1px solid #E2E8F0;font:14px/21px Arial,Helvetica,sans-serif;color:#0F172A">'
    || case when coalesce(head,'') <> '' then '<div style="font-size:15px;line-height:21px;font-weight:bold;padding-bottom:2px">' || head || '</div>' else '' end
    || case when coalesce(lead,'') <> '' then '<b>' || lead || '</b> ' else '' end
    || public.mail_esc(tekst)
    || case when coalesce(sub,'') <> '' then '<div style="font-size:13px;line-height:19px;color:#475569;padding-top:2px">' || sub || '</div>' else '' end
    || coalesce(meta,'') || '</td></tr>' $fn$;

create or replace function public.mail_sg(t text) returns text
 language sql immutable set search_path to 'public' as $fn$
  select '<tr><td style="background:#F8FAFC;border-top:1px solid #E2E8F0;padding:6px 14px;font:bold 11px Arial,Helvetica,sans-serif;letter-spacing:.5px;text-transform:uppercase;color:#64748B">' || public.mail_esc(t) || '</td></tr>' $fn$;

create or replace function public.mail_block(title text, n int, rows text) returns text
 language sql immutable set search_path to 'public' as $fn$
  select case when coalesce(rows,'') = '' then '' else
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #CBD5E1;border-radius:12px;border-collapse:separate;margin:0 0 18px"><tr><td style="background:#EEF2FF;border-left:4px solid #4F46E5;padding:10px 14px;font:bold 13px Arial,Helvetica,sans-serif;letter-spacing:1px;text-transform:uppercase;color:#312E81">'
    || title || case when n is not null then ' <span style="background:#4F46E5;color:#ffffff;padding:1px 7px;border-radius:9px;font-size:11px;letter-spacing:0">' || n || '</span>' else '' end
    || '</td></tr><tr><td style="padding:0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">' || rows || '</table></td></tr></table>' end $fn$;

create or replace function public.week_mail(p_datum date) returns jsonb
 language plpgsql stable set search_path to 'public' as $fn$
declare
  ed editions; k kerncijfers; pk kerncijfers;
  dagen text[] := array['maandag','dinsdag','woensdag','donderdag','vrijdag','zaterdag','zondag'];
  mnd text[] := array['januari','februari','maart','april','mei','juni','juli','augustus','september','oktober','november','december'];
  h text := ''; rows text; r record; g record; n int; i int;
  txt text; pre text; d_rente int; d_swap int; d_marge int; spr int;
  t5 text; cv text; lijst jsonb; cel text; c jsonb;
  vz jsonb;
begin
  select * into ed from editions where soort = 'week' and datum = p_datum;
  if not found then return null; end if;
  select * into k from kerncijfers where datum = ed.datum;
  select * into pk from kerncijfers where datum <= ed.datum - 7 order by datum desc limit 1;

  -- ---------- kop
  h := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td style="font:bold 12px Arial,Helvetica,sans-serif;letter-spacing:1px;text-transform:uppercase;color:#4F46E5">Weekoverzicht</td>'
    || '<td align="right" style="font:13px/19px Arial,Helvetica,sans-serif;color:#64748B">Week ' || extract(week from ed.datum)::int || '<br>' || public.mail_esc(coalesce(ed.periode, dagen[extract(isodow from ed.datum)::int] || ' ' || extract(day from ed.datum)::int || ' ' || mnd[extract(month from ed.datum)::int] || ' ' || extract(year from ed.datum)::int)) || '</td></tr>'
    || '<tr><td colspan="2" style="font:bold 30px/38px Arial,Helvetica,sans-serif;color:#0F172A;padding:2px 0 14px;border-bottom:1px solid #E2E8F0">Hypotheekmarkt</td></tr></table>';

  -- ---------- kerncijfers
  if k.datum is null then
    h := h || '<p style="font:13px/19px Arial,Helvetica,sans-serif;color:#64748B">Geen kerncijfers voor deze week.</p>';
  else
    d_rente := case when pk.rente10_ltv100 is not null and k.rente10_ltv100 is not null then round((k.rente10_ltv100 - pk.rente10_ltv100) * 100)::int end;
    d_swap  := case when pk.swap10 is not null and k.swap10 is not null then round((k.swap10 - pk.swap10) * 100)::int end;
    d_marge := case when pk.marge_bp is not null and k.marge_bp is not null then k.marge_bp - pk.marge_bp end;
    cel := '<td width="33%" valign="top" style="padding:12px 4px 0 0"><div style="border:1px solid #E2E8F0;border-radius:10px;padding:10px 12px;font-family:Arial,Helvetica,sans-serif"><div style="font-size:12px;line-height:16px;color:#64748B">%T%</div><div style="font-size:24px;line-height:30px;font-weight:bold;color:#0F172A;white-space:nowrap">%V%</div><div style="font-size:12px;line-height:16px;color:#64748B">%D%</div>%X%</div></td>';
    h := h || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>'
      || replace(replace(replace(replace(cel,'%T%','Hypotheekrente 10j (100% LTV)'),'%V%',public.mail_pc(k.rente10_ltv100) || '%'),'%D%',public.mail_dl(d_rente)),'%X%','')
      || replace(replace(replace(replace(cel,'%T%','Swaprente 10j'),'%V%',public.mail_pc(k.swap10) || '%'),'%D%',public.mail_dl(d_swap)),'%X%','')
      || replace(replace(replace(replace(cel,'%T%','Rentemarge'),'%V%',coalesce(k.marge_bp::text || ' bp','n.b.')),'%D%',public.mail_dl(d_marge)),'%X%',
           case when k.marge_bp is not null then '<div style="font-size:12px;line-height:16px;font-weight:bold;color:#D97706">norm 125 bp · ' || case when k.marge_bp - 125 > 0 then '+' when k.marge_bp - 125 < 0 then '−' else '±' end || abs(k.marge_bp - 125) || ' bp</div>' else '' end)
      || '</tr></table>';

    -- top 5 tabellen (NHG en 100% LTV naast elkaar)
    t5 := '';
    for g in select * from (values ('Met NHG', k.top5_nhg), ('100% LTV', k.top5_ltv)) as v(titel, lst) loop
      lijst := coalesce(g.lst, '[]'::jsonb);
      n := jsonb_array_length(lijst);
      rows := '';
      i := 0;
      for r in select (e.value ->> 0) as naam, (e.value ->> 1)::numeric as waarde from jsonb_array_elements(lijst) with ordinality as e(value, o) where e.o <= 5 order by e.o loop
        i := i + 1;
        rows := rows || '<tr><td width="16" style="font-size:11px;color:#64748B;padding:2px 0">' || i || '</td><td style="font-size:13px;padding:2px 0;'
          || case when r.naam in ('Argenta','Vista') then 'color:#4F46E5;font-weight:bold' when r.naam in ('Centraal Beheer','CB','Syntrus','Syntrus Achmea','Attens') then 'color:#15803D;font-weight:bold' else '' end
          || '">' || public.mail_esc(r.naam) || '</td><td align="right" style="font-size:13px;font-weight:bold;white-space:nowrap;padding:2px 0">' || public.mail_pc(r.waarde) || '%</td></tr>';
      end loop;
      spr := case when i > 1 then round(((lijst -> (least(n,5) - 1)) ->> 1)::numeric * 100 - ((lijst -> 0) ->> 1)::numeric * 100)::int else 0 end;
      t5 := t5 || '<td width="50%" valign="top" style="padding:0 ' || case when g.titel = 'Met NHG' then '10px' else '0' end || ' 0 0"><div style="font:bold 12px Arial,Helvetica,sans-serif;padding:10px 0 2px">' || g.titel || '</div><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-family:Arial,Helvetica,sans-serif;color:#0F172A">'
        || rows || '<tr><td colspan="3" style="border-top:1px solid #E2E8F0;font-size:11px;color:#64748B;padding-top:2px">Spreiding 1–5: <b>' || spr || ' bp</b></td></tr></table></td>';
    end loop;
    h := h || '<div style="font:bold 11px Arial,Helvetica,sans-serif;letter-spacing:1px;text-transform:uppercase;color:#64748B;padding:20px 0 0">Top 5 laagste tarieven · 10j</div><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>' || t5 || '</tr></table>';

    -- rentecurve NHG
    c := k.curve;
    if c is not null and c ? 'nu' and jsonb_typeof(c -> 'nu') = 'array' then
      cv := '';
      i := 0;
      foreach cel in array array['5j','10j','20j'] loop
        cv := cv || '<tr><td style="font-size:11px;color:#64748B;padding:2px 0">' || cel || '</td>'
          || coalesce((select string_agg('<td align="right" style="font-size:13px;padding:2px 0">' || case when jsonb_typeof(c -> s) = 'array' then public.mail_pc((c -> s ->> i)::numeric) else 'n.b.' end || '</td>', '' order by o)
                       from unnest(array['nu','week','maand']) with ordinality as q(s, o)), '') || '</tr>';
        i := i + 1;
      end loop;
      cv := cv || '<tr><td style="border-top:1px solid #E2E8F0;font-size:11px;color:#64748B;padding:2px 0"><b>steil</b></td>'
        || (select string_agg('<td align="right" style="border-top:1px solid #E2E8F0;font-size:13px;font-weight:bold;padding:2px 0">' || case when jsonb_typeof(c -> s) = 'array' then round(((c -> s ->> 2)::numeric - (c -> s ->> 0)::numeric) * 100)::int || ' bp' else 'n.b.' end || '</td>', '' order by o)
            from unnest(array['nu','week','maand']) with ordinality as q(s, o)) || '</tr>';
      h := h || '<div style="font:bold 11px Arial,Helvetica,sans-serif;letter-spacing:1px;text-transform:uppercase;color:#64748B;padding:18px 0 4px">Rentecurve NHG</div>'
        || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-family:Arial,Helvetica,sans-serif;color:#0F172A"><tr><td></td><td align="right" style="font-size:11px;color:#64748B">nu</td><td align="right" style="font-size:11px;color:#64748B">week</td><td align="right" style="font-size:11px;color:#64748B">maand</td></tr>' || cv || '</table>'
        || '<div style="font:11px/16px Arial,Helvetica,sans-serif;color:#64748B;padding-top:4px">Steilheid = 20j min 5j. Peildata: nu ' || public.mail_dm(nullif(c ->> 'peil','')::date) || ' · week ' || public.mail_dm(nullif(c ->> 'week_peil','')::date) || ' · maand ' || public.mail_dm(nullif(c ->> 'maand_peil','')::date) || '</div>';
    end if;

    h := h || '<div style="font:11px/16px Arial,Helvetica,sans-serif;color:#64748B;padding:12px 0 4px">Rente: gemiddelde van de 5 laagste tarieven 10 jaar vast bij 100% LTV (Moneywise, ' || public.mail_dm(k.rente_peil) || '). Swap: slot ' || public.mail_dm(k.swap_slot) || ' (BlueGamma). Marge: rente − swap, norm 125 bp. Top 5: laagste reguliere tarief per aanbieder, zonder groene producten (Moneywise, ' || public.mail_dm(k.top5_stand) || ').' || case when k.bronnoot is not null then ' ' || public.mail_esc(k.bronnoot) else '' end || '</div>';
  end if;

  h := h || '<div style="height:18px;line-height:18px;font-size:1px">&nbsp;</div>';

  -- ---------- top 5
  rows := ''; i := 0;
  for r in select * from items where edition_id = ed.id and sectie = 'top' order by positie, id loop
    i := i + 1;
    rows := rows || public.mail_row(
      '<span style="display:inline-block;background:#4F46E5;color:#ffffff;width:20px;height:20px;line-height:20px;text-align:center;border-radius:10px;font-size:12px">' || i || '</span> ' || public.mail_esc(r.kop),
      null, r.zin,
      case when r.waarom is not null then '<b>Waarom relevant:</b> ' || public.mail_esc(r.waarom) else '' end,
      public.mail_meta(array[public.mail_pills(to_jsonb(r.labels)), public.mail_src(r.bron_naam, r.bron_url)]));
  end loop;
  if rows = '' then rows := public.mail_row(null, null, 'Geen nieuws van betekenis in deze periode.', null, null); end if;
  h := h || public.mail_block('Top 5 van de week', i, rows);

  -- ---------- watchlist
  rows := '';
  for r in select e.value as w from jsonb_array_elements(case when jsonb_typeof(ed.watch) = 'array' then ed.watch else '[]'::jsonb end) with ordinality as e(value, o) order by e.o loop
    rows := rows || public.mail_row(null, public.mail_esc(r.w ->> 'naam') || public.mail_arrow(r.w ->> 'richting', r.w ->> 'per'), r.w ->> 'tekst', null,
      public.mail_meta(array[case when jsonb_typeof(r.w -> 'bron') = 'array' then public.mail_src(r.w -> 'bron' ->> 0, r.w -> 'bron' ->> 1) else '' end]));
  end loop;
  h := h || public.mail_block('Watchlist', (select count(*)::int from jsonb_array_elements(case when jsonb_typeof(ed.watch) = 'array' then ed.watch else '[]'::jsonb end)), rows);

  -- ---------- bedrijven in beeld
  rows := ''; n := 0;
  for r in select * from items where edition_id = ed.id and sectie = 'bedrijf' order by positie, id loop
    n := n + 1;
    rows := rows || public.mail_row(null, public.mail_esc(r.categorie), r.zin, null, public.mail_meta(array[public.mail_pills(to_jsonb(r.labels)), public.mail_src(r.bron_naam, r.bron_url)]));
  end loop;
  h := h || public.mail_block('Bedrijven in beeld', n, rows);

  -- ---------- nieuws per categorie (categorieën in volgorde van eerste positie)
  rows := ''; n := 0;
  for g in select categorie, min(positie) as mp from items where edition_id = ed.id and sectie = 'nieuws' group by categorie order by min(positie), categorie loop
    rows := rows || public.mail_sg(g.categorie);
    for r in select * from items where edition_id = ed.id and sectie = 'nieuws' and categorie is not distinct from g.categorie order by positie, id loop
      n := n + 1;
      rows := rows || public.mail_row(null, null, r.zin, null, public.mail_meta(array[public.mail_pills(to_jsonb(r.labels)), public.mail_src(r.bron_naam, r.bron_url)]));
    end loop;
  end loop;
  h := h || public.mail_block('Nieuws per categorie', n, rows);

  -- ---------- toezicht & beleid + komende data
  rows := ''; n := 0;
  for g in select categorie, min(positie) as mp from items where edition_id = ed.id and sectie = 'toezicht' group by categorie order by min(positie), categorie loop
    rows := rows || public.mail_sg(g.categorie);
    for r in select * from items where edition_id = ed.id and sectie = 'toezicht' and categorie is not distinct from g.categorie order by positie, id loop
      n := n + 1;
      rows := rows || public.mail_row(null, null, r.zin, case when r.impact is not null then '<b>Impact:</b> ' || public.mail_esc(r.impact) else '' end,
        public.mail_meta(array[public.mail_pills(to_jsonb(r.labels)), public.mail_src(r.bron_naam, r.bron_url)]));
    end loop;
  end loop;
  if jsonb_typeof(ed.agenda) = 'array' and jsonb_array_length(ed.agenda) > 0 then
    rows := rows || public.mail_sg('Komende data');
    for r in select e.value as a from jsonb_array_elements(ed.agenda) with ordinality as e(value, o) order by e.o loop
      rows := rows || public.mail_row(null, public.mail_esc(r.a ->> 'datum') || ' · ' || public.mail_esc(r.a ->> 'instantie'), r.a ->> 'tekst', null, public.mail_meta(array[public.mail_pills(r.a -> 'labels')]));
    end loop;
  end if;
  if rows = '' then rows := public.mail_row(null, null, 'Geen relevante toezicht- of beleidsberichten in deze periode.', null, null); end if;
  h := h || public.mail_block('Toezicht &amp; beleid', nullif(n, 0), rows);

  -- ---------- rente deze week
  rows := ''; n := 0;
  for r in select e.value as x from jsonb_array_elements(case when jsonb_typeof(ed.rente_wijzigingen) = 'array' then ed.rente_wijzigingen else '[]'::jsonb end) with ordinality as e(value, o) order by e.o loop
    n := n + 1;
    rows := rows || public.mail_row(null, public.mail_esc(r.x ->> 'verstrekker') || public.mail_arrow(r.x ->> 'richting', null), r.x ->> 'tekst', null, public.mail_meta(array[public.mail_esc(r.x ->> 'datum')]));
  end loop;
  if rows = '' then rows := public.mail_row(null, null, 'Geen rentewijzigingen gevonden.', null, null); end if;
  vz := ed.vooruitzicht;
  if jsonb_typeof(vz) = 'object' and coalesce(vz ->> 'tekst','') <> '' then
    rows := rows || public.mail_row(null, null, vz ->> 'tekst', null, public.mail_meta(array[case when jsonb_typeof(vz -> 'bron') = 'array' then public.mail_src(vz -> 'bron' ->> 0, vz -> 'bron' ->> 1) else '' end]));
  end if;
  h := h || public.mail_block('Rente deze week', n, rows);

  -- ---------- vooruitblik
  rows := ''; n := 0;
  for r in select e.value as x from jsonb_array_elements(case when jsonb_typeof(ed.vooruitblik) = 'array' then ed.vooruitblik else '[]'::jsonb end) with ordinality as e(value, o) order by e.o loop
    n := n + 1;
    rows := rows || public.mail_row(null, public.mail_esc(r.x ->> 'datum'), r.x ->> 'tekst', null, public.mail_meta(array[public.mail_pills(r.x -> 'labels')]));
  end loop;
  h := h || public.mail_block('Vooruitblik volgende week', n, rows);

  -- ---------- voet
  h := h || '<div style="border-top:1px solid #E2E8F0;padding-top:12px;font:12px/18px Arial,Helvetica,sans-serif;color:#64748B">'
    || case when coalesce(ed.niet_gevonden,'') <> '' then '<b>Niet gevonden of achter betaalmuur:</b> ' || public.mail_esc(ed.niet_gevonden) || '<br>' else '' end
    || case when coalesce(ed.basis,'') <> '' then '<b>Basis:</b> ' || public.mail_esc(ed.basis) || '<br>' else '' end
    || 'Samengesteld door Claude op basis van openbare bronnen. Labels: ' || public.mail_pills('["Hypo"]') || ' hypotheekexpert · ' || public.mail_pills('["Digi"]') || ' digitalisering · ' || public.mail_pills('["Board"]') || ' directie.</div>';

  -- ---------- preheader en omhulsel
  select coalesce(kop, zin) into pre from items where edition_id = ed.id and sectie = 'top' order by positie, id limit 1;
  h := '<!doctype html><html lang="nl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>' || public.mail_esc(ed.onderwerp) || '</title></head>'
    || '<body style="margin:0;padding:0;background:#EEF2F7"><div style="display:none;max-height:0;overflow:hidden;opacity:0;color:#EEF2F7">' || public.mail_esc(pre) || '</div>'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#EEF2F7"><tr><td align="center" style="padding:16px 8px">'
    || '<table role="presentation" width="640" cellpadding="0" cellspacing="0" style="width:100%;max-width:640px;background:#ffffff;border-radius:16px"><tr><td style="padding:22px 24px">'
    || h || '</td></tr></table></td></tr></table></body></html>';

  -- ---------- platte tekst (voor mailprogramma's zonder HTML)
  txt := ed.onderwerp || E'\n\nTop 5 van de week\n';
  i := 0;
  for r in select * from items where edition_id = ed.id and sectie = 'top' order by positie, id loop
    i := i + 1;
    txt := txt || i || '. ' || coalesce(r.kop, '') || ' - ' || r.zin || coalesce(' (' || r.bron_url || ')', '') || E'\n';
  end loop;
  txt := txt || E'\nDeze nieuwsbrief is opgemaakt in HTML. Open de mail in een programma dat HTML toont om het volledige weekoverzicht te lezen.';

  return jsonb_build_object('onderwerp', ed.onderwerp, 'html', h, 'tekst', txt,
    'items', (select count(*) from items where edition_id = ed.id), 'mail_verzonden_at', ed.mail_verzonden_at);
end $fn$;

-- Alleen de service-/postgres-rol (geplande taken via Supabase-koppeling) mag deze functies aanroepen.
revoke all on function public.week_mail(date) from public, anon, authenticated;
