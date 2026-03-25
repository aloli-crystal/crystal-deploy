require "../spec_helper"
require "base64"

# ─── Helpers ───────────────────────────────────────────────────────────────────

private def make_config(framework : String = "marten") : CrystalDeploy::Config
  yaml = <<-YAML
    app_name: mon-app
    repo_url: git@github.com:test/mon-app.git
    crystal_main: src/mon_app.cr
    keep_releases: 10
    framework: #{framework}
    environments:
      developpement:
        branch: developpement
        host: dev.example.com
        user: deploy
        app_url: https://dev.mon-app.example.com
    YAML
  config = CrystalDeploy::Config.from_yaml(yaml)
  config.environments.each { |name, env| env.name = name }
  config
end

private def make_env(config : CrystalDeploy::Config) : CrystalDeploy::Environment
  config.environment("developpement")
end

# ─── Tests sur Config (framework) ──────────────────────────────────────────────

describe "CrystalDeploy::Config — framework" do
  it "reconnaît le framework marten" do
    config = make_config("marten")
    config.marten?.should be_true
    config.kemal?.should be_false
  end

  it "reconnaît le framework kemal" do
    config = make_config("kemal")
    config.kemal?.should be_true
    config.marten?.should be_false
  end

  it "utilise kemal par défaut si framework absent" do
    yaml = <<-YAML
      app_name: test
      repo_url: git@github.com:test/test.git
      crystal_main: src/test.cr
      keep_releases: 5
      environments:
        dev:
          branch: dev
          host: localhost
          user: deploy
          app_url: https://test.example.com
      YAML
    config = CrystalDeploy::Config.from_yaml(yaml)
    config.kemal?.should be_true
  end
end

# ─── Tests sur Config (load_env_example) ───────────────────────────────────────

describe "CrystalDeploy::Config — load_env_example" do
  it "retourne les variables par défaut si .env.example est absent" do
    config = make_config("marten")
    vars = config.load_env_example("/tmp/nonexistent_env_example_#{Random.rand(99999)}")
    vars.should_not be_empty
    vars.any? { |v| v.key == "SECRET_KEY" }.should be_true
  end

  it "marque MARTEN_ENV comme variable auto-injectée" do
    config = make_config("marten")
    vars = config.load_env_example("/tmp/nonexistent_env_example_#{Random.rand(99999)}")
    marten_env = vars.find { |v| v.key == "MARTEN_ENV" }
    marten_env.should_not be_nil
    marten_env.not_nil!.is_marten_auto.should be_true
  end

  it "marque SECRET_KEY comme variable à générer" do
    config = make_config("marten")
    vars = config.load_env_example("/tmp/nonexistent_env_example_#{Random.rand(99999)}")
    secret = vars.find { |v| v.key == "SECRET_KEY" }
    secret.should_not be_nil
    secret.not_nil!.is_generated.should be_true
  end

  it "marque DB_HOST comme variable PostgreSQL pour Marten" do
    config = make_config("marten")
    vars = config.load_env_example("/tmp/nonexistent_env_example_#{Random.rand(99999)}")
    db_host = vars.find { |v| v.key == "DB_HOST" }
    db_host.should_not be_nil
    db_host.not_nil!.is_pg.should be_true
  end

  it "marque DATABASE_URL comme variable PostgreSQL pour Kemal" do
    config = make_config("kemal")
    vars = config.load_env_example("/tmp/nonexistent_env_example_#{Random.rand(99999)}")
    db_url = vars.find { |v| v.key == "DATABASE_URL" }
    db_url.should_not be_nil
    db_url.not_nil!.is_pg.should be_true
  end

  it "parse correctement un .env.example avec commentaires" do
    tmp = File.tempfile("env_example") do |f|
      f.print <<-ENV
        # Clé secrète de l'application
        # [généré]
        SECRET_KEY=

        # Base de données
        DB_HOST=localhost
        DB_PORT=5432
        DB_USER=mon_app
        DB_PASSWORD=
        DB_NAME=mon_app_dev

        # SMTP (optionnel)
        SMTP_HOST=
        ENV
    end

    config = make_config("marten")
    vars = config.load_env_example(tmp.path)

    secret = vars.find { |v| v.key == "SECRET_KEY" }
    secret.should_not be_nil
    secret.not_nil!.is_generated.should be_true

    db_host = vars.find { |v| v.key == "DB_HOST" }
    db_host.should_not be_nil
    db_host.not_nil!.default_value.should eq("localhost")

    tmp.delete
  end
end

# ─── Tests sur Environment ─────────────────────────────────────────────────────

describe "CrystalDeploy::Environment" do
  it "extrait le hostname depuis app_url" do
    config = make_config
    env = make_env(config)
    env.hostname.should eq("dev.mon-app.example.com")
  end

  it "génère le socket_path correct" do
    config = make_config
    env = make_env(config)
    env.socket_path("mon-app").should eq("/tmp/.mon-app--developpement.sock")
  end

  it "génère le full_name correct" do
    config = make_config
    env = make_env(config)
    env.full_name("mon-app").should eq("mon-app--developpement")
  end

  it "génère le service_rc_name correct" do
    config = make_config
    env = make_env(config)
    env.service_rc_name("mon-app").should eq("mon_app__developpement")
  end

  it "déduit la zone DNS depuis app_url" do
    config = make_config
    env = make_env(config)
    env.dns_zone.should eq("mon-app.example.com")
  end
end

# ─── Tests sur la génération de valeurs aléatoires ─────────────────────────────

describe "CrystalDeploy — génération de valeurs" do
  it "génère une clé hex de 64 caractères" do
    value = Random::Secure.hex(32)
    value.size.should eq(64)
    value.should match(/\A[0-9a-f]+\z/)
  end

  it "génère un mot de passe base64 non vide" do
    value = Base64.strict_encode(Random::Secure.random_bytes(15)).tr("+/=", "")[0, 20]
    value.size.should be > 0
    value.size.should be <= 20
  end
end


# ─── Tests sur la lecture du .env local (clés OVH uniquement) ──────────────────
#
# Le .env local est réservé au développement. La commande `init` ne l'utilise
# PAS pour pré-remplir les variables de déploiement. Il est uniquement lu
# pour en extraire les clés OVH si elles y sont présentes.

describe "CrystalDeploy::Config — load_env_local" do
  it "retourne un hash vide si le fichier .env est absent" do
    config = make_config
    result = config.load_env_local("/tmp/nonexistent_env_test")
    result.should be_empty
  end

  it "lit les variables d'un .env" do
    tmp = File.tempfile("test_local_env") do |f|
      f.print "OVH_APP_KEY=mykey\nOVH_APP_SECRET=mysecret\nSECRET_KEY=ma_cle\nDB_HOST=localhost\n"
    end
    config = make_config
    result = config.load_env_local(tmp.path)
    result["OVH_APP_KEY"].should eq("mykey")
    result["SECRET_KEY"].should eq("ma_cle")
    result["DB_HOST"].should eq("localhost")
    tmp.delete
  end

  it "ignore les commentaires et lignes vides" do
    tmp = File.tempfile("test_local_env_comments") do |f|
      f.print "# Commentaire\nOVH_APP_KEY=mykey\n\nOVH_APP_SECRET=mysecret\n"
    end
    config = make_config
    result = config.load_env_local(tmp.path)
    result.size.should eq(2)
    result["OVH_APP_KEY"].should eq("mykey")
    tmp.delete
  end

  it "ignore les valeurs qui sont des commandes shell" do
    tmp = File.tempfile("test_local_env_shell") do |f|
      f.print "PORT=marten serve\nAPP_HOST=127.0.0.1\nOVH_APP_KEY=mykey\n"
    end
    config = make_config
    result = config.load_env_local(tmp.path)
    result.has_key?("PORT").should be_false
    result["APP_HOST"].should eq("127.0.0.1")
    result["OVH_APP_KEY"].should eq("mykey")
    tmp.delete
  end
end

# ─── Tests sur la lecture des clés OVH ──────────────────────────────────────────

describe "CrystalDeploy — lecture clés OVH depuis .env" do
  it "lit les clés OVH depuis un fichier .env temporaire" do
    tmp = File.tempfile("test_env") do |f|
      f.print "OVH_APP_KEY=mykey\nOVH_APP_SECRET=mysecret\nOVH_CONSUMER_KEY=myconsumer\n"
    end

    app_key = ""
    app_secret = ""
    consumer_key = ""

    File.each_line(tmp.path) do |line|
      next if line.starts_with?("#") || line.strip.empty?
      k, _, v = line.partition("=")
      case k.strip
      when "OVH_APP_KEY"      then app_key      = v.strip
      when "OVH_APP_SECRET"   then app_secret   = v.strip
      when "OVH_CONSUMER_KEY" then consumer_key = v.strip
      end
    end

    app_key.should eq("mykey")
    app_secret.should eq("mysecret")
    consumer_key.should eq("myconsumer")

    tmp.delete
  end
end
