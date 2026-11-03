# redmine_team

Self-hosted [Redmine 6.1.5](https://www.redmine.org/) running in Docker against a
shared **TiDB Cloud Serverless** database (`redmine_1`), so several machines can
work on the same issues, comments, users and custom fields.

## Prerequisites

- Docker + Docker Compose
- Network access to TiDB Cloud outbound on port `4000`
- The shared `.env` (sent out-of-band, never committed)

## Quick start

```bash
git clone <repo-url> redmine_team
cd redmine_team
cp .env.example .env
# Fill in DB_USERNAME, DB_PASSWORD, REDMINE_SECRET_KEY_BASE from the shared .env
docker compose up -d --build
```

First build pulls `redmine:6.1.5` and compiles assets; allow several minutes
before the healthcheck goes green (`start_period: 180s`).

Open `http://localhost:${REDMINE_HOST_PORT:-8080}` (default 8080).

## Configuration

All secrets live in `.env` (gitignored). See `.env.example` for the full list:

| Key | Notes |
|---|---|
| `DB_USERNAME` / `DB_PASSWORD` | TiDB Cloud credentials for `redmine_1` |
| `REDMINE_SECRET_KEY_BASE` | Must be **identical** on every machine sharing the DB |
| `REDMINE_HOST_PORT` | Host port (default 8080) |
| `REDMINE_NO_DB_MIGRATE` | Empty on the migration owner, `1` everywhere else |

## Operational notes

### Migrations — one owner only

The image entrypoint runs `rake db:migrate` at startup unless
`REDMINE_NO_DB_MIGRATE` is non-empty. With several instances sharing one
database, letting all of them migrate means concurrent runs of the same
migration, which can fail and crash-loop.

- Leave `REDMINE_NO_DB_MIGRATE` **empty** on the migration-owner machine.
- Set `REDMINE_NO_DB_MIGRATE=1` on every other machine.
- On a Redmine upgrade: rebuild the owner first and let it migrate. Other
  instances keep serving `503` until migration finishes, then recover (the
  healthcheck reports this correctly).

### Attachments do not sync

Issues, comments, wiki, users and custom fields are shared via TiDB, but
uploaded files live in the local `redmine_files` volume. An attachment
uploaded on one machine is only available there. This is documented, not
solved.

### Copy `.env` verbatim

Sessions use `cookie_store`, so sharing `REDMINE_SECRET_KEY_BASE` makes a
login cookie issued by one instance valid on the others. Regenerating the key
silently logs everyone out on the other instance and breaks signed tokens
(e.g. password-reset links).

## Troubleshooting

- **TiDB Cloud Serverless IP restrictions**: if access is locked down, the
  teammate's IP must be allowed, and outbound port `4000` must not be blocked
  by their network.
- **Stale volumes after rebuild**: named volumes are seeded from the image only
  on first use. After rebuilding with a new Redmine version, refresh them:
  `docker compose down`, remove the disposable `redmine_assets` volume, then
  `docker compose up -d --build`. See `VOLUMES.md` for the full procedure.
- **Port already in use**: set `REDMINE_HOST_PORT` in `.env`.
- **Slow first start**: the healthcheck `start_period` is 180s; first build
  can take several minutes.
