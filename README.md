# Hypotheekmarkt

Privé nieuwsoverzicht van de Nederlandse hypotheekmarkt. Drie onderdelen, één repo.

```
Geplande taken (Claude)  ──schrijven──▶  Supabase (data)  ◀──lezen──  Website (deze repo)
```

| Onderdeel | Waar | In deze repo |
|---|---|---|
| Website | statische bestanden, leest live uit Supabase na inloggen | `index.html`, `app.js`, `style.css`, `config.js` |
| Database | Supabase-project `Hypotheeknieuwsdatabase` (`bxxoimlsvkpauatfxuqz`, eu-west-1) | `supabase/schema.sql`, `supabase/functions.sql`, `supabase/mail.sql`, `supabase/linkedin.sql` |
| Dagelijkse runs | Geplande taken in Claude | `runs/*.md` (kopie van elke prompt) |

## Geplande taken

| Tijd (Europe/Amsterdam) | Taak | Bestand |
|---|---|---|
| ma–vr 06:40 | LinkedIn-radar: posts van de volglijst (bedrijven en bestuurders) | `runs/linkedinrun.md` |
| ma–vr 06:55 | Feedrun: RSS en nieuwspagina's uit tabel `bronnen` | `runs/feedrun.md` |
| ma–vr 07:10 | Dagrun: onderzoek door subagents, kerncijfers, top 3 | `runs/dagrun-onderzoek.md` |
| vr 09:00 | Weekoverzicht, opgebouwd uit de dagedities | `runs/weekoverzicht.md` |
| ma–vr 09:30 | Controle (alleen lezen, vrijdag ook weekedite, ook LinkedIn-run), meldt OK, LET OP of ALARM | `runs/controle-dagrun.md` |
| vr 10:00 | Weekmail: weekoverzicht als HTML-nieuwsbrief in de mailbody naar guido.hendrikx2@achmea.nl | `runs/weekmail.md` |

De prompts in `runs/` zijn kopieën. De geplande taak zelf in Claude is de bron van waarheid; houd de kopie bij als de taak verandert.

## Beveiliging

- De publishable key in `config.js` is bedoeld voor de browser.
- Alle tabellen hebben row level security. Alleen ingelogde gebruikers mogen lezen, schrijven kan niet via de browser.
- Nieuwe aanmeldingen staan uit in Supabase Auth (controleer dit na wijzigingen aan Auth-instellingen).

## Werkwijze

- Wijzigingen worden door Claude gepusht naar de branch `claude/updates`, nooit direct naar `main`.
- Na review merge je naar `main`. Een statische host (GitHub Pages, Cloudflare Pages of Netlify) publiceert `main`.
- Databasewijzigingen gaan via een Supabase-migratie. Leg ze daarna vast in `supabase/`.

## Nieuwsbrief (weekmail)

`select public.week_mail('JJJJ-MM-DD')` (vrijdagdatum) geeft `{onderwerp, html, tekst, items, mail_verzonden_at}`. De HTML is e-mailveilig (tabellen, inline CSS, geen JavaScript of afbeeldingen) en heeft dezelfde inhoud en volgorde als de weekpagina. De geplande taak `runs/weekmail.md` verstuurt hem via Gmail en zet `editions.mail_verzonden_at`, zodat er nooit twee keer wordt gemaild. De functie is niet aanroepbaar voor `anon`/`authenticated`.

## LinkedIn-radar

Volgt openbare LinkedIn-activiteit van de belangrijkste bedrijven (Achmea, Argenta, Vista, Stater, Quion, Ohpen, HDN, Yellowtail/Davinci/Conclusion, Blinqx, ROMEO, Oper) en hun bestuurders.

- **Volglijst**: tabel `linkedin_accounts` (bedrijfspagina's en personen, met functie, bron en peildatum van die functie, prioriteit 1–3, LinkedIn-vanity `slug`). Aanpassen kan met SQL in Supabase of door het in een chat te vragen. Zet `actief=false` in plaats van te verwijderen.
- **Hoe posts binnenkomen**: LinkedIn blokkeert geautomatiseerd ophalen en verbiedt scrapen, dus de run leest LinkedIn niet zelf. Hij zoekt via zoekmachines naar openbare posts en via de media naar uitspraken van gevolgde bestuurders. Een post wordt alleen opgeslagen als de datum vaststaat:
  1. uit de postlink zelf: het activity-ID bevat het plaatsingstijdstip (`ID >> 22` = milliseconden sinds 1970), zie `linkedin_ts()`;
  2. uit een expliciete `datePublished` in het zoekresultaat;
  3. uit de publicatiedatum van een media-artikel (`gevonden_via = 'media'`).
  Relatieve leeftijden ("3w") worden nooit gebruikt. Dekking is daardoor niet volledig: posts verschijnen soms pas dagen later, en niet elke post is vindbaar.
- **Opslag**: `linkedin_posts` (kern in eigen woorden, waarom, thema, labels, relevantie 1–3; geen volledige posttekst), `linkedin_runs` (log per run). De run schrijft alleen via `linkedin_voeg_toe(jsonb)`, die links normaliseert, datums afleidt en controleert, ontdubbelt en de run logt. Signalen (mogelijke functiewissels) komen in `linkedin_accounts.opmerking`; de run wijzigt functies niet zelf.
- **Website**: tab LinkedIn (filters, activiteit per bedrijf, volglijst met signalen), blok "Nieuw op LinkedIn" in de dagweergave (posts die die ochtend zijn gevonden) en "LinkedIn deze week" in de weekweergave.
- **Weekmail**: blok "LinkedIn deze week" (zaterdag t/m vrijdag, relevantie ≥ 2, maximaal 8). Zonder posts verschijnt het blok niet en is de mail identiek aan voorheen.
