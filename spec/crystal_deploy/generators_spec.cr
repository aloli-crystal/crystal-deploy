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

  it "inclut les directives error_page 502/503/504 pointant vers shared/public" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Nginx.new(config, env)
    content = gen.generate
    content.should contain("error_page 502 503 504 /erreur-indisponible.html")
    content.should contain("location = /erreur-indisponible.html")
    content.should contain("/home/mon-app--developpement/shared/public")
    content.should contain("internal")
  end
end

describe CrystalDeploy::Generators::Rcd do
  it "génère un script rc.d avec le bon nom de service" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Rcd.new(config, env)
    content = gen.generate
    content.should contain("name=\"mon_app__developpement\"")
    # rcvar utilise ${name} pour être résolu dynamiquement par rc.subr
    content.should contain("rcvar=\"${name}_enable\"")
  end

  it "génère un wrapper shell qui charge le .env avant de lancer le binaire" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Rcd.new(config, env)
    content = gen.generate
    # La fonction _generate_wrapper doit être présente
    content.should contain("_generate_wrapper")
    # Le wrapper copie env_exports.sh pré-généré par Crystal
    content.should contain("env_exports.sh")
    content.should_not contain("set -a")
    # daemon(8) doit lancer le wrapper, pas le binaire directement
    content.should contain("mon_app__developpement_wrapper")
    # Le wrapper est dans shared/bin/
    content.should contain("shared/bin/mon-app--developpement")
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

  it "utilise un seul pidfile (superviseur daemon) et non un double pidfile" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Rcd.new(config, env)
    content = gen.generate
    # Un seul pidfile (-P pour le superviseur daemon)
    content.should contain("-P \"${mon_app__developpement_pidfile}\"")
    # Pas de pidfile_child (supprimé — le wrapper gère le processus)
    content.should_not contain("pidfile_child")
  end

  it "inclut la directive REQUIRE postgresql pour le démarrage ordonné" do
    config, env = sample_config_and_env
    gen = CrystalDeploy::Generators::Rcd.new(config, env)
    content = gen.generate
    # La variable _require doit être définie avec postgresql comme valeur par défaut
    content.should contain("mon_app__developpement_require")
    content.should contain("postgresql")
    # REQUIRE doit être assigné depuis la variable configurable
    content.should contain("REQUIRE=")
  end
end
