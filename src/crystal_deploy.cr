require "yaml"
require "colorize"

require "./crystal_deploy/config"
require "./crystal_deploy/logger"
require "./crystal_deploy/cli"
require "./crystal_deploy/commands/deploy"
require "./crystal_deploy/commands/init"
require "./crystal_deploy/commands/rollback"
require "./crystal_deploy/commands/status"
require "./crystal_deploy/commands/generate_ci"
require "./crystal_deploy/commands/ovh_setup"
require "./crystal_deploy/generators/github_workflow"
require "./crystal_deploy/generators/nginx"
require "./crystal_deploy/generators/rcd"
require "./crystal_deploy/ssh/client"
require "./crystal_deploy/ssh/remote_script"
require "./crystal_deploy/ssh/remote_runner"

module CrystalDeploy
  VERSION = "0.1.0"
end
