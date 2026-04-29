require "../spec_helper"

describe Deploy::Config do
  describe "chargement depuis YAML" do
    it "charge les champs de base" do
      config = SpecHelper.marten_config
      config.app_name.should eq("test-app")
      config.framework.should eq("marten")
      config.database.should eq("postgresql")
      config.keep_releases.should eq(5)
    end

    it "détecte marten?" do
      SpecHelper.marten_config.marten?.should be_true
      SpecHelper.kemal_config.marten?.should be_false
    end

    it "détecte kemal?" do
      SpecHelper.kemal_config.kemal?.should be_true
      SpecHelper.marten_config.kemal?.should be_false
    end

    it "charge la configuration DNS" do
      config = SpecHelper.marten_config
      config.dns_registrar.should eq("ovh")
      config.dns_zone.should eq("example.app")
    end

    it "retourne nil pour dns_registrar si absent" do
      config = SpecHelper.kemal_config
      config.dns_registrar.should be_nil
    end

    it "charge les environnements" do
      config = SpecHelper.marten_config
      config.environments.size.should eq(2)
      config.environments.has_key?("developpement").should be_true
      config.environments.has_key?("production").should be_true
    end
  end

  describe "résolution d'environnement" do
    it "retourne l'environnement exact avec son nom" do
      config = SpecHelper.marten_config
      env = config.environment("developpement")
      env.host.should eq("dev.example.com")
      env.name.should eq("developpement")
    end

    it "calcule full_name" do
      env = SpecHelper.dev_env(SpecHelper.marten_config)
      env.full_name("test-app").should eq("test-app--developpement")
    end

    it "calcule socket_path" do
      env = SpecHelper.dev_env(SpecHelper.marten_config)
      env.socket_path("test-app").should eq("/tmp/.test-app--developpement.sock")
    end

    it "calcule service_rc_name (tirets → underscores)" do
      env = SpecHelper.dev_env(SpecHelper.marten_config)
      env.service_rc_name("test-app").should eq("test_app__developpement")
    end

    it "calcule hostname depuis app_url" do
      env = SpecHelper.dev_env(SpecHelper.marten_config)
      env.hostname.should eq("dev.test-app.example.app")
    end

    it "calcule effective_dns_subdomain" do
      env = SpecHelper.dev_env(SpecHelper.marten_config)
      env.effective_dns_subdomain.should eq("dev")
    end

    it "calcule effective_dns_target (fallback sur host)" do
      env = SpecHelper.dev_env(SpecHelper.marten_config)
      env.effective_dns_target.should eq("dev.example.com.")
    end
  end
end

describe Deploy::EnvVarsConfig do
  it "charge depuis YAML" do
    yaml = "required:\n  - key: SECRET_KEY\n    secret: true\n    generate: hex64\nskip:\n  - MARTEN_ENV\n  - DB_HOST\n"
    rules = Deploy::EnvVarsConfig.from_yaml(yaml)
    rules.required.size.should eq(1)
    rules.required.first.key.should eq("SECRET_KEY")
    rules.required.first.secret.should be_true
    rules.required.first.generate.should eq("hex64")
    rules.skip.should contain("MARTEN_ENV")
    rules.skip.should contain("DB_HOST")
  end

  it "retourne un objet vide par défaut" do
    rules = Deploy::EnvVarsConfig.new
    rules.required.should be_empty
    rules.skip.should be_empty
  end

  it "skip? retourne true pour les clés ignorées" do
    yaml = "required: []\nskip:\n  - MARTEN_ENV\n  - APP_HOST\n"
    rules = Deploy::EnvVarsConfig.from_yaml(yaml)
    rules.skip?("MARTEN_ENV").should be_true
    rules.skip?("SECRET_KEY").should be_false
  end
end

describe Deploy::Config, "#effective_env_vars" do
  it "inclut les skip par défaut même sans section env_vars" do
    config = SpecHelper.marten_config
    rules = config.effective_env_vars
    rules.skip.should contain("MARTEN_ENV")
    rules.skip.should contain("DB_HOST")
    rules.skip.should contain("APP_HOST")
    rules.skip.should contain("DB_NAME_TEST")
  end

  it "fusionne les skip utilisateur avec les skip par défaut" do
    yaml = <<-YAML
      app_name: test-app
      repo_url: git@github.com:user/test-app.git
      crystal_main: src/server.cr
      framework: marten
      database: postgresql
      env_vars:
        required:
          - key: SECRET_KEY
            secret: true
            generate: hex64
        skip:
          - MA_VAR_LOCALE
      environments:
        developpement:
          branch: developpement
          host: dev.example.com
          user: deploy
          app_url: https://dev.test-app.example.app
    YAML
    config = Deploy::Config.from_yaml(yaml)
    config.environments.each { |name, env| env.name = name }
    rules = config.effective_env_vars
    rules.required.first.key.should eq("SECRET_KEY")
    rules.skip.should contain("MARTEN_ENV")
    rules.skip.should contain("MA_VAR_LOCALE")
  end
end

describe Deploy::Config, "#load_env_example" do
  it "retourne les variables non ignorées et non déjà définies" do
    config = SpecHelper.marten_config
    skip_keys = %w[MARTEN_ENV APP_HOST PORT DB_HOST DB_NAME_TEST]
    already_defined = %w[SECRET_KEY]

    tmp = File.tempfile(".env.example") do |f|
      f.print "MARTEN_ENV=development\nSECRET_KEY=\nAPP_HOST=127.0.0.1\nDB_HOST=localhost\nDB_NAME_TEST=test\n# Serveur SMTP\nSMTP_HOST=\nSMTP_PORT=587\n"
    end

    begin
      vars = config.load_env_example(
        path: tmp.path,
        skip_keys: skip_keys,
        already_defined: already_defined
      )
      keys = vars.map(&.key)
      keys.should contain("SMTP_HOST")
      keys.should contain("SMTP_PORT")
      keys.should_not contain("MARTEN_ENV")
      keys.should_not contain("SECRET_KEY")
      keys.should_not contain("APP_HOST")
      keys.should_not contain("DB_HOST")
      keys.should_not contain("DB_NAME_TEST")
    ensure
      tmp.delete
    end
  end

  it "retourne un tableau vide si .env.example est absent" do
    config = SpecHelper.marten_config
    vars = config.load_env_example(
      path: "/chemin/inexistant/.env.example",
      skip_keys: [] of String,
      already_defined: [] of String
    )
    vars.should be_empty
  end

  it "associe le commentaire à la variable suivante" do
    config = SpecHelper.marten_config
    tmp = File.tempfile(".env.example") do |f|
      f.print "# Serveur SMTP\nSMTP_HOST=\n"
    end
    begin
      vars = config.load_env_example(
        path: tmp.path,
        skip_keys: [] of String,
        already_defined: [] of String
      )
      vars.first.comment.should eq("Serveur SMTP")
    ensure
      tmp.delete
    end
  end
end
