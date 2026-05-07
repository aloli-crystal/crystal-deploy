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
  # Version lue au compile-time depuis `shard.yml` via le macro
  # `read_file` (plus robuste que le précédent shell-out via backticks
  # qui dépendait de `grep`/`sed`/`tr` dans le PATH du builder).
  # Cf. note mémoire `feedback_shard_version_macro.md` (mémoire ALOLI).
  VERSION = {{
              (read_file("#{__DIR__}/../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}
end
