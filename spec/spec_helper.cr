require "spec"
require "../src/deploy"

# Helpers partagés pour les tests
module SpecHelper
  # YAML minimal valide pour Config (Marten + PostgreSQL + OVH)
  MARTEN_YAML = <<-YAML
    app_name: test-app
    repo_url: git@github.com:user/test-app.git
    crystal_main: src/server.cr
    keep_releases: 5
    framework: marten
    database: postgresql
    dns:
      registrar: ovh
      zone: example.app
    environments:
      developpement:
        branch: developpement
        host: dev.example.com
        user: deploy
        app_url: https://dev.test-app.example.app
      production:
        branch: production
        host: prod.example.com
        user: deploy
        app_url: https://test-app.example.app
    YAML

  # YAML minimal valide pour Config (Kemal + PostgreSQL, sans DNS)
  KEMAL_YAML = <<-YAML
    app_name: test-app
    repo_url: git@github.com:user/test-app.git
    crystal_main: src/test_app.cr
    keep_releases: 10
    framework: kemal
    database: postgresql
    environments:
      developpement:
        branch: developpement
        host: dev.example.com
        user: deploy
        app_url: https://dev.test-app.example.app
    YAML

  def self.marten_config : Deploy::Config
    c = Deploy::Config.from_yaml(MARTEN_YAML)
    c.environments.each { |name, env| env.name = name }
    c
  end

  def self.kemal_config : Deploy::Config
    c = Deploy::Config.from_yaml(KEMAL_YAML)
    c.environments.each { |name, env| env.name = name }
    c
  end

  def self.dev_env(config : Deploy::Config) : Deploy::Environment
    config.environment("developpement")
  end
end
