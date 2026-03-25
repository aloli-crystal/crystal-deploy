require "../spec_helper"

# La constante doit être déclarée au niveau du module, pas dans un describe block
SAMPLE_DEPLOY_YAML = <<-YAML
  app_name: mon-app
  repo_url: git@github.com:user/mon-app.git
  crystal_main: src/mon_app.cr
  keep_releases: 5
  environments:
    developpement:
      branch: developpement
      host: dev.example.com
      user: deploy
      app_url: https://dev.mon-app.example.app
      dns_subdomain: dev.mon-app
      dns_target: dev.example.com.
    production:
      branch: production
      host: prod.example.com
      user: deploy
      app_url: https://mon-app.example.app
  env_vars: []
  YAML

describe CrystalDeploy::Config do
  it "charge la configuration depuis YAML" do
    config = CrystalDeploy::Config.from_yaml(SAMPLE_DEPLOY_YAML)
    config.app_name.should eq("mon-app")
    config.keep_releases.should eq(5)
    config.environments.size.should eq(2)
  end

  it "résout un environnement existant" do
    config = CrystalDeploy::Config.from_yaml(SAMPLE_DEPLOY_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.host.should eq("dev.example.com")
    env.branch.should eq("developpement")
  end

  it "calcule le full_name correctement" do
    config = CrystalDeploy::Config.from_yaml(SAMPLE_DEPLOY_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.full_name("mon-app").should eq("mon-app--developpement")
  end

  it "calcule le socket_path correctement (convention /tmp)" do
    config = CrystalDeploy::Config.from_yaml(SAMPLE_DEPLOY_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.socket_path("mon-app").should eq("/tmp/.mon-app--developpement.sock")
  end

  it "calcule le service_rc_name correctement (tirets → underscores)" do
    config = CrystalDeploy::Config.from_yaml(SAMPLE_DEPLOY_YAML)
    config.environments.each { |name, env| env.name = name }
    env = config.environment("developpement")
    env.service_rc_name("mon-app").should eq("mon_app__developpement")
  end
end
