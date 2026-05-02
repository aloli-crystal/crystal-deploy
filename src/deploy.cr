require "yaml"
require "colorize"
require "openssl/hmac"

require "./deploy/i18n"
require "./deploy/logger"
require "./deploy/config"
require "./deploy/dns/base"
require "./deploy/dns/ovh"
require "./deploy/dns/gandi"
require "./deploy/db/base"
require "./deploy/db/postgresql"
require "./deploy/db/sqlite"
require "./deploy/db/mariadb"
require "./deploy/generators/github_workflow"
require "./deploy/generators/nginx"
require "./deploy/generators/rcd"
require "./deploy/env_parser"
require "./deploy/ssh/client"
require "./deploy/ssh/remote_script"
require "./deploy/ssh/remote_runner"
require "./deploy/commands/deploy"
require "./deploy/commands/init"
require "./deploy/commands/rollback"
require "./deploy/commands/status"
require "./deploy/commands/generate_ci"
require "./deploy/cli"

module Deploy
  # Version lue à la compilation depuis `shard.yml` — source unique.
  # Macro Crystal : la commande shell est exécutée au moment du
  # `crystal build`, et son stdout est embarqué comme String literal.
  VERSION = {{ `grep -E '^version:' #{__DIR__}/../shard.yml | head -1 | sed 's/version: *//' | tr -d '[:space:]'`.stringify }}
end
