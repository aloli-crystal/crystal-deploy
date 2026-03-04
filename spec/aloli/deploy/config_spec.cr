require "../../spec_helper"

describe Aloli::Deploy::Config do
  SAMPLE_YAML = <<-YAML
    app_name: mon-app
    repo_url: git@github.com:aloli/mon-app.git
    crystal_main: src/mon_app.cr
    keep_releases: 5
    environments:
      developpement:
        branch: developpement
        host: dev.example.com
        user: deploy
        app_url: https://dev.mon-app.aloli.app
        dns_subdomain: dev.mon-app
        dns_target: dev.example.com.
      production:
        branch: production
        host: prod.example.com
        user: deploy
        app_url: https://mon-app.aloli.app
    env_vars: []
    YAML

  it "charge la configuration depuis YAML" do
    config = Aloli::Deploy::Config.from_yaml(SAMPLE_YAML)
    config.app_name.should eq("mon-app")
    config.keep_releases.should eq(5)
    config.environments.size.should eq(2)
  end

  it "résout un environnement existant" do
    config = Aloli::Deploy::Config.from_yaml(SAMPLE_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.host.should eq("dev.example.com")
    env.branch.should eq("developpement")
  end

  it "calcule le full_name correctement" do
    config = Aloli::Deploy::Config.from_yaml(SAMPLE_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.full_name("mon-app").should eq("mon-app--developpement")
  end

  it "calcule le socket_path correctement" do
    config = Aloli::Deploy::Config.from_yaml(SAMPLE_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.socket_path("mon-app").should eq("/var/run/mon-app/developpement.sock")
  end

  it "calcule le service_rc_name correctement (tirets → underscores)" do
    config = Aloli::Deploy::Config.from_yaml(SAMPLE_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.service_rc_name("mon-app").should eq("mon_app__developpement")
  end
end
