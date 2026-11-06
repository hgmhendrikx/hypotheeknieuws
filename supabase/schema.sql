-- Hypotheeknieuwsdatabase (Supabase project bxxoimlsvkpauatfxuqz, eu-west-1)
-- Schema, gereconstrueerd uit de live database op 2026-11-06.
-- Bedoeld als documentatie en als vertrekpunt voor herstel. Wijzigingen aan de database
-- lopen via een migratie in Supabase; leg ze daarna ook hier vast.

create table public.editions (
  id uuid primary key default gen_random_uuid(),
  soort text not null check (soort in ('dag','week')),
  datum date not null,
  periode text,
  onderwerp text,
  watch jsonb not null default '[]'::jsonb,
  rente_wijzigingen jsonb not null default '[]'::jsonb,
  vooruitzicht jsonb,
  duiding jsonb not null default '[]'::jsonb,
  agenda jsonb not null default '[]'::jsonb,
  vooruitblik jsonb not null default '[]'::jsonb,
  niet_gevonden text,
  basis text,
  mail_verzonden_at timestamptz,
  created_at timestamptz not null default now(),
  constraint editions_soort_datum_key unique (soort, datum)
);

create table public.items (
  id bigint generated always as identity primary key,
  edition_id uuid not null references public.editions(id) on delete cascade,
  sectie text not null check (sectie in ('top','nieuws','toezicht','bedrijf')),
  categorie text,
  positie int not null default 0,
  kop text,
  zin text not null,
  waarom text,
  impact text,
  labels text[] not null default '{}',
  bron_naam text,
  bron_url text,
  nieuws_datum date not null,
  herkomst text not null default 'dagrun' check (herkomst in ('dagrun','feed')),
  item_key text generated always as (md5(sectie || '|' || coalesce(categorie, '') || '|' || zin)) stored,
  created_at timestamptz not null default now(),
  constraint items_edition_id_item_key_key unique (edition_id, item_key)
);

create index items_edition_idx on public.items using btree (edition_id, sectie, positie);
create index items_labels_idx on public.items using gin (labels);
create index items_nieuws_datum_idx on public.items using btree (nieuws_datum);
create index items_zoek_idx on public.items using gin (
  to_tsvector('dutch'::regconfig, coalesce(kop, '') || ' ' || zin || ' ' || coalesce(categorie, ''))
);

create table public.kerncijfers (
  datum date primary key,
  rente10_ltv100 numeric,
  rente_peil date,
  swap10 numeric,
  swap_slot date,
  marge_bp int,
  top5_stand date,
  top5_nhg jsonb,
  top5_ltv jsonb,
  curve jsonb,
  bronnoot text,
  created_at timestamptz not null default now()
);

create table public.bronnen (
  id bigint generated always as identity primary key,
  naam text not null,
  instantie text not null,
  feed_url text not null unique,
  type text not null default 'rss' check (type in ('rss','pagina')),
  sectie text not null default 'toezicht' check (sectie in ('nieuws','toezicht','bedrijf')),
  categorie text,
  labels text[] not null default '{}',
  filter_modus text not null default 'zoekwoorden' check (filter_modus in ('alles','zoekwoorden')),
  actief boolean not null default true,
  laatste_ok timestamptz,
  laatste_fout text,
  laatste_aantal int,
  geverifieerd_op date,
  created_at timestamptz not null default now()
);

-- Trigger: nieuws_datum standaard gelijk aan de datum van de uitgave
create trigger items_nieuws_datum before insert on public.items
  for each row execute function public.items_set_nieuws_datum();

-- Row level security: alleen ingelogde gebruikers mogen lezen, niemand kan via de browser schrijven.
alter table public.editions enable row level security;
alter table public.items enable row level security;
alter table public.kerncijfers enable row level security;
alter table public.bronnen enable row level security;

create policy "alleen ingelogd lezen" on public.editions for select to authenticated using (true);
create policy "alleen ingelogd lezen" on public.items for select to authenticated using (true);
create policy "alleen ingelogd lezen" on public.kerncijfers for select to authenticated using (true);
create policy "ingelogd leest bronnen" on public.bronnen for select to authenticated using (true);

-- Functies: zie functions.sql (maak die aan nadat de tabellen bestaan; items_set_nieuws_datum
-- moet bestaan voordat de trigger wordt aangemaakt).
