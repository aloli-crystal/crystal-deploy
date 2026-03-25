require "../spec_helper"

private def sample_config_and_env
  yaml = <<-YAML
    app_name: mon-app
    repo_url: git@github.com:user/mon-app.git
    crystal_main: src/mon_app.cr
    keep_releases: 10
    environments:
      developpement:
        branch: developpement
        host: dev.example.com
        user: deploy
        app_url: https://dev.mon-app.example.app
    env_vars: []
    YAML
  config = CrystalDeploy::Config.from_yaml(yaml)
  config.environments.each { |name, env| env.name = name }
  env = config.environment("developpement")
  {config, env}
end

describe CrystalDeploy::Generators::Nginx do
  it "génère un nginx.conf avec le bon server_name (sans https://)" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Nginx.new(config, env)
    content = gen.generate
    content.should contain("server_name dev.mon-app.example.app")
    content.should_not contain("https://")
  end

  it "génère le bon upstream avec le socket Unix" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Nginx.new(config, env)
    content = gen.generate
    content.should contain("server unix:/tmp/.mon-app--developpement.sock")
  end

  it "inclut le bloc HTTPS commenté" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Nginx.new(config, env)
    content = gen.generate
    content.should contain("listen 443 ssl http2")
    content.should contain("# server {")
  end
end

describe CrystalDeploy::Generators::Rcd do
  it "génère un script rc.d avec le bon nom de service" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Rcd.new(config, env)
    content = gen.generate
    content.should contain("name=\"mon_app__developpement\"")
    content.should contain("rcvar=\"mon_app__developpement_enable\"")
  end

  it "contient la boucle d'attente sur pidfile et socket" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Rcd.new(config, env)
    content = gen.generate
    content.should contain("WAIT=0")
    content.should contain("mon_app__developpement_pidfile")
    content.should contain("mon_app__developpement_socket")
  end

  it "applique chown deploy:www sur le socket" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Rcd.new(config, env)
    content = gen.generate
    content.should contain("chown")
    content.should contain("www")
    content.should contain("chmod 660")
  end
end
