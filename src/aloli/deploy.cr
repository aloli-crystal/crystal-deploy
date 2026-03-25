require "yaml"
require "colorize"

require "./deploy/config"
require "./deploy/logger"
require "./deploy/cli"
require "./deploy/commands/deploy"
require "./deploy/commands/init"
require "./deploy/commands/rollback"
require "./deploy/commands/status"
require "./deploy/commands/generate_ci"
require "./deploy/commands/ovh_setup"
require "./deploy/generators/github_workflow"
require "./deploy/generators/nginx"
require "./deploy/generators/rcd"
require "./deploy/ssh/client"
require "./deploy/ssh/remote_script"
require "./deploy/ssh/remote_runner"

module Aloli
  module Deploy
    VERSION = "0.1.0"
  end
end
