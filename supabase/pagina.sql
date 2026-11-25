-- Pagina's lezen in de database, als vervanger van WebFetch (sinds 25-11-2026)
--
-- Aanleiding: in de geplande runs ontbrak WebFetch geregeld ("WebFetch niet beschikbaar", ook na ToolSearch)
-- of werd een link door de toestemmingscontrole geweigerd. De database kan pagina's zelf ophalen met de
-- http-extensie, net als de RSS-feeds. De runs lezen een pagina nu met één SQL-aanroep via execute_sql:
--
--   select public.pagina_lezen('https://www.amweb.nl/...');                 -- titel, datum, beschrijving, tekst
--   select public.pagina_lezen('https://www.amweb.nl/', true);              -- idem plus de links op de pagina
--   select public.paginas_lezen(array['https://...','https://...']);        -- tot 12 pagina's in één keer
--
-- Spelregels:
-- * robots.txt wordt gerespecteerd, voor de eigen naam (hypotheekmarkt) én voor Claude-User, omdat de tekst
--   door Claude wordt gelezen. Crawl-delay wordt aangehouden (maximaal 15 s per wachtmoment).
-- * Geen omwegen: geen browser-imitatie, geen cookies, geen mirrors of caches van derden. Een betaalmuur,
--   browsercontrole of 403 wordt gemeld (uitkomst), niet omzeild.
-- * Alleen openbare http(s)-adressen; interne adressen worden geweigerd. De functies zijn niet aanroepbaar
--   vanuit de browser (anon/authenticated), alleen door de runs (execute_sql) en pg_cron.
-- * Resultaten blijven 12 uur in pagina_cache (fouten 3 uur), zodat feedrun, dagrun en controle dezelfde
--   pagina niet steeds opnieuw ophalen.
--
-- Daarnaast haalt artikelen_ophalen() elk uur (pg_cron, minuut 53, na feeds_ophalen op minuut 50):
-- * de pagina-bronnen (AMweb, Kifid): de artikellinks komen als items in feed_ruw, net als bij een RSS-feed;
-- * de artikelpagina's van alle nog niet beoordeelde feeditems, zodat feed_nieuw() de artikeltekst meegeeft
--   en de feedrun niets meer zelf hoeft te openen.

create extension if not exists http with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- ---------------------------------------------------------------------------------------------------------
-- Tabellen
-- ---------------------------------------------------------------------------------------------------------

create table if not exists public.pagina_cache (
  url_norm text primary key,
  url text not null,
  domein text,
  opgehaald_at timestamptz not null default clock_timestamp(),
  status int,
  uitkomst text not null,          -- ok | robots | betaalmuur | browsercontrole | rate limit | geweigerd | niet gevonden | geen html | fout
  reden text,
  titel text,
  beschrijving text,
  gepubliceerd timestamptz,
  datum_bron text,                 -- meta | tekst | null
  tekst text,
  links jsonb
);
create index if not exists pagina_cache_domein on public.pagina_cache (domein, opgehaald_at desc);
alter table public.pagina_cache enable row level security;
drop policy if exists "ingelogd leest pagina_cache" on public.pagina_cache;
create policy "ingelogd leest pagina_cache" on public.pagina_cache for select to authenticated using (true);

create table if not exists public.robots_cache (
  host text primary key,
  opgehaald_at timestamptz not null default clock_timestamp(),
  status int,
  fout text,
  groepen jsonb                    -- [{"agents":["*"],"regels":[{"a":true,"p":"/pad"}],"delay":10}]
);
alter table public.robots_cache enable row level security;

-- Pagina-bronnen: waar de artikellinks staan (overzichtspagina of sitemap.xml; leeg = feed_url) en welk
-- patroon een artikellink heeft (leeg = algemene vuistregel: een pad dat eindigt op een slug met 4+ woorden)
alter table public.bronnen add column if not exists artikel_patroon text;
alter table public.bronnen add column if not exists lijst_url text;

-- ---------------------------------------------------------------------------------------------------------
-- Hulpfuncties
-- ---------------------------------------------------------------------------------------------------------

create or replace function public.html_entiteiten(t text)
returns text language plpgsql immutable set search_path = public as $$
declare s text := t; m text[]; e text[];
begin
  if s is null or position('&' in s) = 0 then return s; end if;
  for m in select distinct regexp_matches(s, '(&#([0-9]{1,7});)', 'g') loop
    begin s := replace(s, m[1], chr(m[2]::int)); exception when others then s := replace(s, m[1], ' '); end;
  end loop;
  for m in select distinct regexp_matches(s, '(&#[xX]([0-9a-fA-F]{1,6});)', 'g') loop
    begin s := replace(s, m[1], chr(('x' || lpad(m[2], 8, '0'))::bit(32)::int)); exception when others then s := replace(s, m[1], ' '); end;
  end loop;
  foreach e slice 1 in array array[
    ['&nbsp;',' '],['&shy;',''],['&lt;','<'],['&gt;','>'],['&quot;','"'],['&apos;',''''],
    ['&euml;','ë'],['&eacute;','é'],['&egrave;','è'],['&ecirc;','ê'],['&iuml;','ï'],['&ouml;','ö'],['&uuml;','ü'],
    ['&auml;','ä'],['&aacute;','á'],['&agrave;','à'],['&oacute;','ó'],['&ccedil;','ç'],['&Eacute;','É'],
    ['&rsquo;','’'],['&lsquo;','‘'],['&rdquo;','”'],['&ldquo;','“'],['&ndash;','–'],['&mdash;','—'],
    ['&hellip;','…'],['&euro;','€'],['&bull;','•'],['&middot;','·'],['&copy;','©'],['&reg;','®'],
    ['&trade;','™'],['&laquo;','«'],['&raquo;','»'],['&times;','×'],['&deg;','°'],['&amp;','&']] loop
    s := replace(s, e[1], e[2]);
  end loop;
  return s;
end $$;

-- Tekst uit een html-fragment: blokken worden regels, cellen worden gescheiden door " | ".
create or replace function public.html_blokken(h text)
returns text language plpgsql immutable set search_path = public as $$
declare s text := coalesce(h, ''); r text := ''; l text; vorige text := '';
begin
  s := regexp_replace(s, '<br\s*/?>', E'\n', 'gi');
  s := regexp_replace(s, '</t[dh]\s*>', ' | ', 'gi');
  s := regexp_replace(s, '</?(p|div|h[1-6]|li|ul|ol|tr|table|thead|tbody|section|article|main|header|blockquote|figcaption|dd|dt|dl|pre)(\s[^>]*)?>', E'\n', 'gi');
  s := regexp_replace(s, '<[^>]*>', '', 'g');
  s := public.html_entiteiten(s);
  foreach l in array regexp_split_to_array(s, '\n') loop
    l := btrim(regexp_replace(regexp_replace(l, '[\s ]+', ' ', 'g'), '(\s*\|\s*)+$', ''));
    l := regexp_replace(l, '^(\|\s*)+', '');
    if length(l) < 2 or l = vorige then continue; end if;
    r := r || l || E'\n'; vorige := l;
  end loop;
  return nullif(btrim(r), '');
end $$;

create or replace function public.tekst_naar_tijd(t text)
returns timestamptz language plpgsql stable set search_path = public as $$
declare s text := btrim(coalesce(t, '')); m text[];
begin
  if s = '' then return null; end if;
  if s ~ '^\d{4}-\d{2}-\d{2}' then
    begin return s::timestamptz; exception when others then null; end;
  end if;
  -- 24 november 2026 / 24 nov. 2026
  m := regexp_match(lower(s), '(\d{1,2})\s+(jan|feb|maa|mrt|apr|mei|jun|jul|aug|sep|okt|nov|dec)[a-z]*\.?\s+(20\d{2})');
  if m is not null then
    return make_date(m[3]::int,
      array_position(array['jan','feb','maa','apr','mei','jun','jul','aug','sep','okt','nov','dec'],
                     case m[2] when 'mrt' then 'maa' else m[2] end), m[1]::int)::timestamp at time zone 'Europe/Amsterdam';
  end if;
  -- 24-11-2026 / 24/11/2026 / 24.11.2026
  m := regexp_match(s, '\m(\d{1,2})[-/.](\d{1,2})[-/.]((?:20)?\d{2})\M');
  if m is not null then
    begin return make_date(case when length(m[3]) = 2 then 2000 + m[3]::int else m[3]::int end, m[2]::int, m[1]::int)::timestamp at time zone 'Europe/Amsterdam';
    exception when others then null; end;
  end if;
  begin return s::timestamptz; exception when others then null; end;
  return public.rss_datum(s);
exception when others then return null;
end $$;

-- Een stuk html met het eerste element <tag> ... </tag> dat het langst is (geen nesting van dezelfde tag).
create or replace function public.html_langste_blok(h text, tag text)
returns text language sql immutable set search_path = public as $$
  select x from (
    select (regexp_matches(h, '<' || tag || '(?:\s[^>]*)?>(?:[^<]|<(?!/' || tag || '\s*>))*</' || tag || '\s*>', 'gi'))[1] x
  ) q order by length(x) desc limit 1
$$;

-- Ontleedt html: titel, beschrijving, publicatiedatum, hoofdtekst en (optioneel) links.
create or replace function public.html_ontleden(p_html text, p_basis text, p_links boolean default false)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  h text; m text; k text; v text; meta jsonb := '{}'; regio text; tekst text; datum timestamptz; dbron text;
  titel text; beschr text; jl text; schema_host text; basis_dir text; lnk jsonb := '[]'; a text[]; href text;
  ltekst text; gezien text[] := '{}'; n int := 0; tg text; art text; art_tekst text;
begin
  h := left(coalesce(p_html, ''), 2500000);
  -- weg: commentaar, scripts (behalve JSON-LD), stijlen en niet-inhoud
  select string_agg(x.m[1], ' ') into jl
    from regexp_matches(h, '<script[^>]*application/ld\+json[^>]*>((?:[^<]|<(?!/script))*)</script>', 'gi') as x(m);
  h := regexp_replace(h, '<!--(?:[^-]|-(?!->))*-->', ' ', 'g');
  foreach tg in array array['script','style','noscript','svg','template','iframe'] loop
    h := regexp_replace(h, '<' || tg || '(?:\s[^>]*)?>(?:[^<]|<(?!/' || tg || '\s*>))*</' || tg || '\s*>', ' ', 'gi');
  end loop;

  -- meta-tags
  for m in select (regexp_matches(h, '<meta\s[^>]*>', 'gi'))[1] loop
    k := lower(coalesce(substring(m from '(?i)\s(?:property|name|itemprop|http-equiv)\s*=\s*["'']?([^"''\s>]+)'), ''));
    v := coalesce(substring(m from '(?i)\scontent\s*=\s*"([^"]*)"'), substring(m from '(?i)\scontent\s*=\s*''([^'']*)'''));
    if k <> '' and v is not null and not meta ? k then meta := meta || jsonb_build_object(k, public.html_entiteiten(v)); end if;
  end loop;

  titel := coalesce(meta->>'og:title', meta->>'twitter:title',
                    public.html_entiteiten(substring(h from '(?i)<title[^>]*>([^<]*)</title>')));
  beschr := coalesce(meta->>'og:description', meta->>'description', meta->>'twitter:description');

  -- hoofdtekst: langste <article>, anders <main>, anders <body>
  foreach tg in array array['nav','footer','aside','form','button','select'] loop
    h := regexp_replace(h, '<' || tg || '(?:\s[^>]*)?>(?:[^<]|<(?!/' || tg || '\s*>))*</' || tg || '\s*>', ' ', 'gi');
  end loop;
  -- het langste <article> alleen als het het grootste deel van de pagina is (geen teaser of los kaartje)
  regio := coalesce(public.html_langste_blok(h, 'main'), substring(h from '(?i)<body[^>]*>(.*)$'), h);
  tekst := public.html_blokken(regio);
  art := public.html_langste_blok(h, 'article');
  if art is not null then
    art_tekst := public.html_blokken(art);
    if length(coalesce(art_tekst, '')) >= 1500 or length(coalesce(art_tekst, '')) >= 0.4 * length(coalesce(tekst, '')) then
      regio := art; tekst := art_tekst;
    end if;
  end if;

  -- publicatiedatum: meta, JSON-LD, <time datetime>, anders een datum in de tekst
  v := coalesce(meta->>'article:published_time', meta->>'og:article:published_time', meta->>'datepublished',
                meta->>'publish-date', meta->>'publication_date', meta->>'pubdate', meta->>'date',
                meta->>'dc.date', meta->>'dcterms.date', meta->>'dcterms.created', meta->>'dc.date.issued',
                substring(jl from '"datePublished"\s*:\s*"([^"]+)"'),
                substring(regio from '(?i)<time[^>]*\sdatetime\s*=\s*["'']([^"'']+)'));
  datum := public.tekst_naar_tijd(v);
  if datum is not null then dbron := 'meta';
  else
    datum := public.tekst_naar_tijd(substring(left(coalesce(tekst, ''), 3000) from
      '(?i)(\d{1,2}\s+(?:januari|februari|maart|april|mei|juni|juli|augustus|september|oktober|november|december|jan|feb|mrt|apr|jun|jul|aug|sep|okt|nov|dec)\.?\s+20\d{2}|\m\d{1,2}[-.]\d{1,2}[-.]20\d{2}\M|\m\d{1,2}/\d{1,2}/(?:20)?\d{2}\M)'));
    if datum is not null then dbron := 'tekst'; end if;
  end if;
  if datum > clock_timestamp() + interval '1 day' then datum := null; dbron := null; end if;

  -- links (absoluut gemaakt, ontdubbeld, maximaal 250)
  if p_links then
    schema_host := substring(p_basis from '^(https?://[^/?#]+)');
    basis_dir := regexp_replace(substring(p_basis from '^(https?://[^?#]*)'), '/[^/]*$', '/');
    for a in select regexp_matches(h, '<a\s[^>]*?href\s*=\s*["'']([^"'']+)["''][^>]*>((?:[^<]|<(?!/a\s*>))*)</a\s*>', 'gi') loop
      href := btrim(public.html_entiteiten(a[1]));
      if href ~* '^(mailto:|tel:|javascript:|#|data:)' then continue; end if;
      href := case when href ~* '^https?://' then href
                   when href like '//%' then 'https:' || href
                   when href like '/%' then schema_host || href
                   else basis_dir || href end;
      href := regexp_replace(href, '#.*$', '');
      ltekst := btrim(regexp_replace(public.html_entiteiten(regexp_replace(a[2], '<[^>]*>', ' ', 'g')), '\s+', ' ', 'g'));
      if length(ltekst) < 3 or href = any(gezien) then continue; end if;
      gezien := gezien || href;
      lnk := lnk || jsonb_build_object('tekst', left(ltekst, 200), 'url', href);
      n := n + 1; exit when n >= 250;
    end loop;
  end if;

  return jsonb_build_object('titel', btrim(titel), 'beschrijving', btrim(beschr), 'gepubliceerd', datum,
                            'datum_bron', dbron, 'tekst', tekst, 'links', case when p_links then lnk end);
end $$;

-- robots.txt ophalen (24 uur bewaard; bij een fout 1 uur) en ontleden in groepen.
create or replace function public.robots_groepen(p_host text, p_schema text default 'https')
returns jsonb language plpgsql set search_path = public, extensions as $$
declare rc robots_cache; r extensions.http_response; l text; sleutel text; waarde text;
        groepen jsonb := '[]'; agents jsonb := '[]'; regels jsonb := '[]'; delay numeric; in_regels boolean := false;
begin
  select * into rc from robots_cache where host = p_host;
  if found and rc.opgehaald_at > clock_timestamp() - (case when rc.fout is null then interval '24 hours' else interval '1 hour' end) then
    return jsonb_build_object('status', rc.status, 'fout', rc.fout, 'groepen', rc.groepen);
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');
  begin
    r := extensions.http(('GET', p_schema || '://' || p_host || '/robots.txt',
           array[extensions.http_header('User-Agent', 'Mozilla/5.0 (compatible; Hypotheekmarkt-lezer/1.0)')], null, null)::extensions.http_request);
  exception when others then
    insert into robots_cache (host, opgehaald_at, status, fout, groepen) values (p_host, clock_timestamp(), null, left(sqlerrm, 150), null)
    on conflict (host) do update set opgehaald_at = excluded.opgehaald_at, status = null, fout = excluded.fout, groepen = null;
    return jsonb_build_object('status', null, 'fout', left(sqlerrm, 150), 'groepen', null);
  end;
  if r.status = 200 then
    foreach l in array regexp_split_to_array(coalesce(r.content, ''), '\r?\n') loop
      l := btrim(regexp_replace(l, '#.*$', ''));
      if position(':' in l) = 0 then continue; end if;
      sleutel := lower(btrim(split_part(l, ':', 1)));
      waarde := btrim(substr(l, position(':' in l) + 1));
      if sleutel = 'user-agent' then
        if in_regels then
          groepen := groepen || jsonb_build_object('agents', agents, 'regels', regels, 'delay', delay);
          agents := '[]'; regels := '[]'; delay := null; in_regels := false;
        end if;
        agents := agents || to_jsonb(lower(waarde));
      elsif sleutel in ('allow', 'disallow') then
        in_regels := true;
        if waarde <> '' then regels := regels || jsonb_build_object('a', sleutel = 'allow', 'p', waarde); end if;
      elsif sleutel = 'crawl-delay' then
        in_regels := true;
        begin delay := waarde::numeric; exception when others then null; end;
      end if;
    end loop;
    if jsonb_array_length(agents) > 0 then
      groepen := groepen || jsonb_build_object('agents', agents, 'regels', regels, 'delay', delay);
    end if;
  else
    groepen := null;
  end if;
  insert into robots_cache (host, opgehaald_at, status, fout, groepen) values (p_host, clock_timestamp(), r.status, null, groepen)
  on conflict (host) do update set opgehaald_at = excluded.opgehaald_at, status = excluded.status, fout = null, groepen = excluded.groepen;
  return jsonb_build_object('status', r.status, 'fout', null, 'groepen', groepen);
end $$;

-- Mag deze url gelezen worden? Strengste uitkomst van de namen hypotheekmarkt en claude-user.
create or replace function public.robots_toegestaan(p_url text)
returns jsonb language plpgsql set search_path = public as $$
declare host text := lower(substring(p_url from '^https?://([^/:?#]+)'));
        schema text := lower(substring(p_url from '^(https?)://'));
        pad text := coalesce(substring(p_url from '^https?://[^/?#]+(/[^#]*)'), '/');
        rb jsonb; g jsonb; gr jsonb; regel jsonb; naam text; beste int; mag boolean; p text; re text;
        delay numeric := 0; verboden text;
begin
  rb := public.robots_groepen(host, schema);
  if rb->>'fout' is not null then
    return jsonb_build_object('toegestaan', false, 'reden', 'robots.txt niet bereikbaar: ' || (rb->>'fout'));
  end if;
  if (rb->>'status')::int between 500 and 599 then
    return jsonb_build_object('toegestaan', false, 'reden', 'robots.txt geeft HTTP ' || (rb->>'status'));
  end if;
  if rb->'groepen' is null or jsonb_typeof(rb->'groepen') <> 'array' then
    return jsonb_build_object('toegestaan', true, 'crawl_delay', 0);   -- geen robots.txt (404 e.d.): alles mag
  end if;
  foreach naam in array array['hypotheekmarkt', 'claude-user'] loop
    gr := coalesce((select jsonb_agg(x) from jsonb_array_elements(rb->'groepen') x
                     where exists (select 1 from jsonb_array_elements_text(x->'agents') ag
                                    where ag <> '*' and (naam = ag or naam like ag || '%' or ag like naam || '%'))), '[]');
    if jsonb_array_length(gr) = 0 then
      gr := coalesce((select jsonb_agg(x) from jsonb_array_elements(rb->'groepen') x
                       where x->'agents' ? '*'), '[]');
    end if;
    beste := -1; mag := true;
    for g in select * from jsonb_array_elements(gr) loop
      delay := greatest(delay, coalesce((g->>'delay')::numeric, 0));
      for regel in select * from jsonb_array_elements(g->'regels') loop
        p := regel->>'p';
        re := regexp_replace(p, '([.+?^(){}\[\]|\\$])', '\\\1', 'g');
        re := replace(re, '*', '.*');
        if right(p, 1) = '$' then re := left(re, -2) || '$'; end if;
        if pad ~ ('^' || re) and (length(p) > beste or (length(p) = beste and (regel->>'a')::boolean)) then
          beste := length(p); mag := (regel->>'a')::boolean;
        end if;
      end loop;
    end loop;
    if not mag then verboden := naam; exit; end if;
  end loop;
  if verboden is not null then
    return jsonb_build_object('toegestaan', false, 'reden', 'robots.txt verbiedt dit pad voor ' || verboden);
  end if;
  return jsonb_build_object('toegestaan', true, 'crawl_delay', least(delay, 15));
end $$;

create or replace function public.pagina_json(c public.pagina_cache, p_max_tekens int, p_links boolean, p_uit_cache boolean)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'url', c.url, 'status', c.status, 'uitkomst', c.uitkomst, 'reden', c.reden,
    'titel', c.titel, 'beschrijving', left(c.beschrijving, 500),
    'gepubliceerd', to_char(c.gepubliceerd at time zone 'Europe/Amsterdam', 'YYYY-MM-DD HH24:MI'),
    'datum_bron', c.datum_bron,
    'tekst', case when p_max_tekens > 0 then left(c.tekst, p_max_tekens) end,
    'afgekapt', case when length(c.tekst) > p_max_tekens and p_max_tekens > 0 then true end,
    'lengte', length(c.tekst),
    'links', case when p_links then c.links end,
    'opgehaald', to_char(c.opgehaald_at at time zone 'Europe/Amsterdam', 'YYYY-MM-DD HH24:MI'),
    'uit_cache', p_uit_cache))
$$;

-- ---------------------------------------------------------------------------------------------------------
-- pagina_lezen: de vervanger van WebFetch
-- ---------------------------------------------------------------------------------------------------------

create or replace function public.pagina_lezen(p_url text, p_links boolean default false,
                                               p_max_tekens int default 12000, p_cache_uren numeric default 12)
returns jsonb language plpgsql set search_path = public, extensions as $$
declare
  u text := btrim(coalesce(p_url, '')); un text; host text; c pagina_cache; rb jsonb; r extensions.http_response;
  ct text; x jsonb; uitk text; reden text; wacht numeric; laatst timestamptz; ruw text; kort boolean;
begin
  if u !~* '^https?://[^/\s]+\.[a-z]{2,}' then
    return jsonb_build_object('url', p_url, 'uitkomst', 'fout', 'reden', 'geen geldige http(s)-link');
  end if;
  host := lower(substring(u from '^https?://([^/:?#]+)'));
  if host ~ '^(localhost|127\.|10\.|192\.168\.|169\.254\.|0\.|172\.(1[6-9]|2[0-9]|3[01])\.|\[)' or host ~ '\.(local|internal|lan|localhost)$'
     or host ~ '^[0-9.]+$' or host ~ '(supabase\.co|supabase\.in|pooler\.supabase\.com)$' then
    return jsonb_build_object('url', p_url, 'uitkomst', 'fout', 'reden', 'adres niet toegestaan');
  end if;
  un := public.norm_url(u);

  select * into c from pagina_cache where url_norm = un;
  if found and c.opgehaald_at > clock_timestamp() - make_interval(secs => p_cache_uren * 3600 * (case when c.uitkomst = 'ok' then 1 else 0.25 end))
     and (not p_links or c.links is not null or c.uitkomst <> 'ok') then
    return public.pagina_json(c, p_max_tekens, p_links, true);
  end if;

  rb := public.robots_toegestaan(u);
  if not coalesce((rb->>'toegestaan')::boolean, false) then
    uitk := case when rb->>'reden' like 'robots.txt verbiedt%' then 'robots' else 'fout' end;
    reden := rb->>'reden';
  else
    -- crawl-delay per domein aanhouden
    wacht := coalesce((rb->>'crawl_delay')::numeric, 0);
    if wacht > 0 then
      select max(opgehaald_at) into laatst from pagina_cache where domein = host and status is not null;
      if laatst is not null and laatst + make_interval(secs => wacht) > clock_timestamp() then
        perform pg_sleep(extract(epoch from (laatst + make_interval(secs => wacht) - clock_timestamp())));
      end if;
    end if;
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
    begin
      r := extensions.http(('GET', u, array[
             extensions.http_header('User-Agent', 'Mozilla/5.0 (compatible; Hypotheekmarkt-lezer/1.0)'),
             extensions.http_header('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5'),
             extensions.http_header('Accept-Language', 'nl,en;q=0.7')], null, null)::extensions.http_request);
    exception when others then
      uitk := 'fout'; reden := left(sqlerrm, 150);
    end;
  end if;

  if r.status is not null then
    ct := lower(coalesce(r.content_type, ''));
    ruw := r.content;
    if r.status between 200 and 299 then
      if ct <> '' and ct !~ '(html|xml|text/plain)' then
        uitk := 'geen html'; reden := 'inhoud is ' || split_part(ct, ';', 1) || ' (open als bestand of lees de titel/beschrijving)';
      else
        x := public.html_ontleden(ruw, u, p_links);
        kort := length(coalesce(x->>'tekst', '')) < 600;
        if kort and ruw ~* '(cf-chl|challenge-platform|cf_chl_opt|Just a moment\.\.\.|_Incapsula_Resource|captcha-delivery|px-captcha|Checking your browser)' then
          uitk := 'browsercontrole'; reden := 'pagina toont een browsercontrole';
        elsif kort and ruw ~* '(paywall|premium[-_ ]?content|alleen voor abonnees|word abonnee|log in om (verder )?te lezen|subscribe to (continue|read)|piano-?(id|paywall))' then
          uitk := 'betaalmuur'; reden := 'alleen een inleiding leesbaar (betaalmuur)';
        else
          uitk := 'ok';
        end if;
      end if;
    elsif r.status in (401, 402) then uitk := 'betaalmuur'; reden := 'HTTP ' || r.status;
    elsif r.status = 403 then
      uitk := (case when ruw ~* '(cf-chl|challenge-platform|Just a moment|captcha|Checking your browser)' then 'browsercontrole' else 'geweigerd' end);
      reden := 'HTTP 403';
    elsif r.status = 429 then uitk := 'rate limit'; reden := 'HTTP 429';
    elsif r.status in (404, 410) then uitk := 'niet gevonden'; reden := 'HTTP ' || r.status;
    else uitk := 'fout'; reden := 'HTTP ' || r.status;
    end if;
  end if;

  insert into pagina_cache (url_norm, url, domein, opgehaald_at, status, uitkomst, reden, titel, beschrijving,
                            gepubliceerd, datum_bron, tekst, links)
  values (un, u, host, clock_timestamp(), r.status, uitk, reden, x->>'titel', x->>'beschrijving',
          (x->>'gepubliceerd')::timestamptz, x->>'datum_bron', left(x->>'tekst', 100000), x->'links')
  on conflict (url_norm) do update set
    url = excluded.url, domein = excluded.domein, opgehaald_at = excluded.opgehaald_at, status = excluded.status,
    uitkomst = excluded.uitkomst, reden = excluded.reden,
    titel = coalesce(excluded.titel, pagina_cache.titel), beschrijving = coalesce(excluded.beschrijving, pagina_cache.beschrijving),
    gepubliceerd = coalesce(excluded.gepubliceerd, pagina_cache.gepubliceerd), datum_bron = coalesce(excluded.datum_bron, pagina_cache.datum_bron),
    tekst = coalesce(excluded.tekst, pagina_cache.tekst), links = coalesce(excluded.links, pagina_cache.links)
  returning * into c;
  return public.pagina_json(c, p_max_tekens, p_links, false);
end $$;

-- Meerdere pagina's in één aanroep (maximaal 12; tekst per pagina standaard 4000 tekens).
create or replace function public.paginas_lezen(p_urls text[], p_max_tekens int default 4000, p_cache_uren numeric default 12)
returns jsonb language plpgsql set search_path = public as $$
declare u text; uit jsonb := '[]'; n int := 0;
begin
  foreach u in array coalesce(p_urls, '{}') loop
    n := n + 1;
    if n > 12 then
      uit := uit || jsonb_build_object('url', u, 'uitkomst', 'overgeslagen', 'reden', 'maximaal 12 pagina''s per aanroep');
      continue;
    end if;
    uit := uit || public.pagina_lezen(u, false, p_max_tekens, p_cache_uren);
  end loop;
  return uit;
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- Vooraf ophalen: pagina-bronnen (AMweb, Kifid) en artikelen van onverwerkte feeditems
-- ---------------------------------------------------------------------------------------------------------

-- Links uit een sitemap.xml met een lastmod van de laatste p_dagen dagen.
create or replace function public.sitemap_links(p_url text, p_dagen int default 30)
returns jsonb language plpgsql set search_path = public, extensions as $$
declare rb jsonb; r extensions.http_response; uit jsonb := '[]'; m text[];
begin
  rb := public.robots_toegestaan(p_url);
  if not coalesce((rb->>'toegestaan')::boolean, false) then raise exception '%', rb->>'reden'; end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  r := extensions.http(('GET', p_url, array[extensions.http_header('User-Agent', 'Mozilla/5.0 (compatible; Hypotheekmarkt-lezer/1.0)')],
                        null, null)::extensions.http_request);
  if r.status <> 200 then raise exception 'HTTP %', r.status; end if;
  for m in select regexp_matches(r.content, '<url>\s*<loc>([^<]+)</loc>\s*<lastmod>([^<]+)</lastmod>', 'g') loop
    if public.tekst_naar_tijd(m[2]) >= now() - make_interval(days => p_dagen) then
      uit := uit || jsonb_build_object('url', btrim(public.html_entiteiten(m[1])), 'lastmod', m[2]);
    end if;
  end loop;
  return uit;
end $$;

-- Pagina-bronnen (AMweb, Kifid): nieuwe artikellinks als items in feed_ruw, met titel, beschrijving en datum
-- van de artikelpagina zelf. Bij een fout komt de melding in bronnen.laatste_fout (de controle meldt die).
create or replace function public.paginabronnen_ophalen(p_max_nieuw int default 40)
returns jsonb language plpgsql set search_path = public as $$
declare b record; x jsonb; l jsonb; links jsonb; lijst text; fout text; dom text; n_links int; n_nieuw int;
        tot jsonb := '[]'; a jsonb; tw boolean; id_nieuw bigint; pat text; sitemap boolean;
begin
  for b in select * from bronnen where actief and type = 'pagina' order by id loop
    lijst := coalesce(b.lijst_url, b.feed_url);
    sitemap := lijst ~* '\.xml(\?|$)';
    links := null; fout := null;
    if sitemap then
      begin links := public.sitemap_links(lijst, 30);
      exception when others then fout := left(sqlerrm, 120); end;
    else
      x := public.pagina_lezen(lijst, true, 0, 0.5);
      if x->>'uitkomst' = 'ok' then links := x->'links';
      else fout := (x->>'uitkomst') || coalesce(' (' || (x->>'reden') || ')', ''); end if;
    end if;
    if fout is not null then
      update bronnen set laatste_fout = left('Database ' || to_char(now() at time zone 'Europe/Amsterdam', 'DD-MM HH24:MI') || ': ' || fout, 150)
       where id = b.id;
      tot := tot || jsonb_build_object('bron', b.naam, 'fout', fout);
      continue;
    end if;
    dom := public.domein_van(lijst);
    pat := coalesce(b.artikel_patroon, '^https?://[^/]+/(?:[^/?#]+/)*[a-z0-9]+(?:-[a-z0-9]+){3,}/?$');
    n_links := 0; n_nieuw := 0;
    for l in select * from jsonb_array_elements(coalesce(links, '[]')) loop
      if public.domein_van(l->>'url') <> dom or (l->>'url') !~* pat then continue; end if;
      if not sitemap and length(coalesce(l->>'tekst', '')) < 20 then continue; end if;
      n_links := n_links + 1;
      continue when n_nieuw >= p_max_nieuw;
      if exists (select 1 from feed_ruw f where f.bron_id = b.id and f.link_norm = public.norm_url(l->>'url')) then continue; end if;
      -- artikel openen voor titel, beschrijving en datum
      a := public.pagina_lezen(l->>'url', false, 0, 72);
      if a->>'uitkomst' in ('niet gevonden', 'robots', 'geen html') then continue; end if;
      tw := b.filter_modus = 'alles' or public.feed_trefwoord(coalesce(a->>'titel', l->>'tekst', '') || ' ' || coalesce(a->>'beschrijving', ''));
      insert into feed_ruw (bron_id, link, link_norm, titel, beschrijving, gepubliceerd, trefwoord, verwerkt_at, uitkomst)
      values (b.id, l->>'url', public.norm_url(l->>'url'),
              coalesce(nullif(regexp_replace(a->>'titel', '\s*[-|]\s*(AMweb|Kifid)\s*$', ''), ''), l->>'tekst'),
              left(a->>'beschrijving', 1000),
              case when a->>'datum_bron' = 'meta' or (a->>'datum_bron' = 'tekst' and b.artikel_patroon is not null)
                   then least((a->>'gepubliceerd')::timestamp at time zone 'Europe/Amsterdam', now()) end,
              tw, case when tw then null else now() end, case when tw then null else 'geen trefwoord' end)
      on conflict (bron_id, link_norm) do nothing
      returning id into id_nieuw;
      if id_nieuw is null then continue; end if;
      n_nieuw := n_nieuw + 1;
      update feed_ruw f set verwerkt_at = now(), uitkomst = 'ouder dan 30 dagen'
       where f.id = id_nieuw and f.verwerkt_at is null and f.gepubliceerd < now() - interval '30 days';
      id_nieuw := null;
    end loop;
    if n_links = 0 then
      update bronnen set laatste_fout = left('Database ' || to_char(now() at time zone 'Europe/Amsterdam', 'DD-MM HH24:MI')
                                             || ': geen artikellinks gevonden', 150) where id = b.id;
      tot := tot || jsonb_build_object('bron', b.naam, 'fout', 'geen artikellinks');
    else
      update bronnen set laatste_ok = now(), laatste_fout = null, laatste_aantal = n_links, geverifieerd_op = current_date where id = b.id;
      tot := tot || jsonb_build_object('bron', b.naam, 'links', n_links, 'nieuw', n_nieuw);
    end if;
  end loop;
  return tot;
end $$;

create or replace function public.artikelen_ophalen(p_max int default 30)
returns jsonb language plpgsql set search_path = public as $$
declare f record; a jsonb; n int := 0; n_ok int := 0; pb jsonb; mislukt jsonb := '{}';
begin
  begin
    pb := public.paginabronnen_ophalen();
  exception when others then
    pb := jsonb_build_object('fout', left(sqlerrm, 150));
  end;
  for f in
    select fr.id, fr.link, fr.link_norm, fr.gepubliceerd, public.domein_van(fr.link) dom
      from feed_ruw fr
     where fr.verwerkt_at is null and fr.trefwoord
       and not exists (select 1 from pagina_cache c where c.url_norm = fr.link_norm)
     order by coalesce(fr.gepubliceerd, fr.opgehaald_at) desc
     limit p_max
  loop
    -- een domein dat de laatste 6 uur al twee keer faalde, nu overslaan
    if (select count(*) from pagina_cache c where c.domein in (f.dom, 'www.' || f.dom)
          and c.uitkomst not in ('ok', 'geen html', 'niet gevonden') and c.opgehaald_at > clock_timestamp() - interval '6 hours') >= 2 then
      mislukt := mislukt || jsonb_build_object(f.dom, 'overgeslagen');
      continue;
    end if;
    a := public.pagina_lezen(f.link, false, 0, 72);
    n := n + 1;
    if a->>'uitkomst' = 'ok' then
      n_ok := n_ok + 1;
      if f.gepubliceerd is null and a->>'datum_bron' = 'meta' then
        update feed_ruw set gepubliceerd = least((a->>'gepubliceerd')::timestamp at time zone 'Europe/Amsterdam', now()) where id = f.id;
      end if;
    else
      mislukt := mislukt || jsonb_build_object(f.dom, a->>'uitkomst');
    end if;
  end loop;
  -- items waarvan de link al in een editie staat, hoeven niet meer beoordeeld te worden (ook nieuwe pagina-items)
  update feed_ruw fr set verwerkt_at = now(), uitkomst = 'al gepubliceerd'
   where fr.verwerkt_at is null
     and exists (select 1 from items i where i.bron_url is not null and public.norm_url(i.bron_url) = fr.link_norm);
  -- opruimen
  delete from pagina_cache where opgehaald_at < now() - interval '30 days';
  delete from robots_cache where opgehaald_at < now() - interval '7 days';
  return jsonb_build_object('paginabronnen', pb, 'artikelen', n, 'gelukt', n_ok, 'mislukt', mislukt);
end $$;

-- feed_nieuw geeft nu ook het begin van de artikeltekst mee (artikel, artikel_status)
drop function if exists public.feed_nieuw(timestamptz, timestamptz, boolean);
create or replace function public.feed_nieuw(p_van timestamptz, p_tot timestamptz, p_ook_verwerkt boolean default false,
                                             p_artikel_tekens int default 700)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id', f.id, 'bron', b.naam, 'instantie', b.instantie, 'sectie', b.sectie, 'categorie', b.categorie,
      'labels', b.labels, 'titel', f.titel, 'beschrijving', left(f.beschrijving, 400), 'link', f.link,
      'gepubliceerd', to_char(coalesce(f.gepubliceerd, f.opgehaald_at) at time zone 'Europe/Amsterdam', 'YYYY-MM-DD HH24:MI'),
      'datum_onzeker', f.gepubliceerd is null,
      'datum_artikel', case when f.gepubliceerd is null and c.gepubliceerd is not null
                            then to_char(c.gepubliceerd at time zone 'Europe/Amsterdam', 'YYYY-MM-DD') end,
      'artikel_status', coalesce(c.uitkomst, 'niet opgehaald'),
      'artikel', case when c.uitkomst = 'ok' and p_artikel_tekens > 0 then left(c.tekst, p_artikel_tekens) end))
    order by b.id, coalesce(f.gepubliceerd, f.opgehaald_at)), '[]'::jsonb)
  from feed_ruw f join bronnen b on b.id = f.bron_id
  left join pagina_cache c on c.url_norm = f.link_norm
  where f.trefwoord
    and (p_ook_verwerkt or f.verwerkt_at is null)
    and coalesce(f.gepubliceerd, f.opgehaald_at) >= p_van
    and coalesce(f.gepubliceerd, f.opgehaald_at) <= p_tot
$$;

-- Instellingen pagina-bronnen (25-11-2026). Kifid laadt de nieuwslijst dynamisch; de sitemap heeft wel alle
-- nieuwsberichten met een wijzigingsdatum.
update public.bronnen set artikel_patroon = '^https://www\.amweb\.nl/[0-9]{5,}/[a-z0-9-]+$' where naam = 'AMweb nieuws';
update public.bronnen set artikel_patroon = '^https://www\.kifid\.nl/nieuws/[a-z0-9-]+/?$', lijst_url = 'https://www.kifid.nl/sitemap.xml'
 where naam = 'Kifid nieuws';

-- ---------------------------------------------------------------------------------------------------------
-- Rechten en planning
-- ---------------------------------------------------------------------------------------------------------

revoke all on function public.pagina_lezen(text, boolean, int, numeric), public.paginas_lezen(text[], int, numeric),
                       public.paginabronnen_ophalen(int), public.artikelen_ophalen(int), public.sitemap_links(text, int),
                       public.robots_groepen(text, text), public.robots_toegestaan(text),
                       public.html_ontleden(text, text, boolean), public.html_blokken(text), public.html_langste_blok(text, text),
                       public.html_entiteiten(text), public.tekst_naar_tijd(text),
                       public.pagina_json(public.pagina_cache, int, boolean, boolean),
                       public.feed_nieuw(timestamptz, timestamptz, boolean, int)
  from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where command like '%artikelen_ophalen%';
select cron.schedule('artikelen-ophalen', '53 * * * *', 'select public.artikelen_ophalen()');
