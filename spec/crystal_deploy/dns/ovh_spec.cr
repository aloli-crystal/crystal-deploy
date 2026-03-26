require "../../spec_helper"

describe CrystalDeploy::DNS::Ovh do
  it "credentials_present? retourne false si les clés sont vides" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    ovh = CrystalDeploy::DNS::Ovh.new(config, env)
    ovh.credentials_present?.should be_false
  end

  it "registrar_name retourne OVH" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    ovh = CrystalDeploy::DNS::Ovh.new(config, env)
    ovh.registrar_name.should eq("OVH")
  end

  it "load_credentials lit depuis les variables d'environnement" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    ovh = CrystalDeploy::DNS::Ovh.new(config, env)

    ENV["OVH_APP_KEY"]      = "test_app_key"
    ENV["OVH_APP_SECRET"]   = "test_app_secret"
    ENV["OVH_CONSUMER_KEY"] = "test_consumer_key"

    ovh.load_credentials
    ovh.credentials_present?.should be_true

    ENV.delete("OVH_APP_KEY")
    ENV.delete("OVH_APP_SECRET")
    ENV.delete("OVH_CONSUMER_KEY")
  end
end

describe CrystalDeploy::DNS::Factory do
  it "instancie DNS::Ovh pour registrar=ovh" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    dns = CrystalDeploy::DNS::Factory.for("ovh", config, env)
    dns.should be_a(CrystalDeploy::DNS::Ovh)
  end

  it "retourne nil si registrar est nil" do
    config = SpecHelper.kemal_config
    env = SpecHelper.dev_env(config)
    dns = CrystalDeploy::DNS::Factory.for(nil, config, env)
    dns.should be_nil
  end
end
