# Names added to the (named) volumes declared in compose.yaml:
#   redmine_team_redmine_config   -> /usr/src/redmine/config
#   redmine_team_redmine_plugins  -> /usr/src/redmine/plugins
#   redmine_team_redmine_assets   -> /usr/src/redmine/public/assets

# When a named volume is mounted over a path that already contains files, Docker
# copies the image content in on first use and never refreshes it. So after
# rebuilding the image with a new Redmine/TiDB version, refresh those volumes:
#
#   docker compose down
#   docker volume rm redmine_team_redmine_assets   # disposable, regenerated
#   docker compose up -d --build
#
# Before removing the config volume, preserve anything you changed inside it:
#   docker run --rm -v redmine_team_redmine_config:/config -v "$PWD":/backup \
#     alpine tar czf /backup/redmine_config_$(date +%F).tgz -C /config .
#
# The plugins volume survives rebuilds on purpose; the bundled plugins are not
# refreshed, so check for security updates to them manually.
