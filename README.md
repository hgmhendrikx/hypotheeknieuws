# Hypotheekmarkt

Privé nieuwsoverzicht van de Nederlandse hypotheekmarkt. Drie onderdelen, één repo.

```
Geplande taken (Claude)  ──schrijven──▶  Supabase (data)  ◀──lezen──  Website (deze repo)
```

| Onderdeel | Waar | In deze repo |
|---|---|---|
| Website | statische bestanden, leest live uit Supabase na inloggen | `index.html`, `app.js`, `style.css`, `config.js` |
| Database | Supabase-project `Hypotheeknieuwsdatabase` (`bxxoimlsvkpauatfxuqz`, eu-west-1) | `supabase/schema.sql`, `supabase/functions.sql`, `supabase/mail.sql` |
| Dagelijkse runs | Geplande taken in Claude | `runs/*.md` (kopie van elke prompt) |

## Geplande taken

| Tijd (Europe/Amsterdam) | Taak | Bestand |
|---|---|---|
| ma–vr 06:55 | Feedrun: RSS en nieuwspagina's uit tabel `bronnen` | `runs/feedrun.md` |
| ma–vr 07:10 | Dagrun: onderzoek door subagents, kerncijfers, top 3 | `runs/dagrun-onderzoek.md` |
| vr 09:00 | Weekoverzicht, opgebouwd uit de dagedities | `runs/weekoverzicht.md` |
| ma–vr 09:30 | Controle (alleen lezen, vrijdag ook weekedite), meldt OK of ALARM | `runs/controle-dagrun.md` |
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
