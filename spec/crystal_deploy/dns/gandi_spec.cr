require "../../spec_helper"

describe CrystalDeploy::DNS::Gandi do
  it "registrar_name retourne Gandi" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    gandi = CrystalDeploy::DNS::Gandi.new(config, env)
    gandi.registrar_name.should eq("Gandi")
  end

  it "credentials_present? retourne false si le PAT est vide" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    gandi = CrystalDeploy::DNS::Gandi.new(config, env)
    gandi.credentials_present?.should be_false
  end

  it "load_credentials lit GANDI_PAT depuis les variables d'environnement" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    gandi = CrystalDeploy::DNS::Gandi.new(config, env)

    ENV["GANDI_PAT"] = "test_pat_12345"
    gandi.load_credentials
    gandi.credentials_present?.should be_true
    ENV.delete("GANDI_PAT")
  end

  it "load_credentials lit GANDI_PAT depuis un fichier .env local" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    gandi = CrystalDeploy::DNS::Gandi.new(config, env)

    ENV.delete("GANDI_PAT")
    tmp = File.tempfile(".env") do |f|
      f.print "# Commentaire\nGANDI_PAT=pat_from_file\nAUTRE=valeur\n"
    end

    # Patch le chemin du fichier .env
    gandi.local_env_path = tmp.path
    gandi.load_credentials
    gandi.credentials_present?.should be_true

    tmp.delete
  end
end

describe CrystalDeploy::DNS::Factory do
  it "instancie DNS::Gandi pour registrar=gandi" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    dns = CrystalDeploy::DNS::Factory.for("gandi", config, env)
    dns.should be_a(CrystalDeploy::DNS::Gandi)
  end

  it "instancie DNS::Ovh pour registrar=ovh" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    dns = CrystalDeploy::DNS::Factory.for("ovh", config, env)
    dns.should be_a(CrystalDeploy::DNS::Ovh)
  end
end
