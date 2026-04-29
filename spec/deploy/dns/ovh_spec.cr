require "../../spec_helper"

describe Deploy::DNS::Ovh do
  it "credentials_present? retourne false si les clés sont vides" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    ovh = Deploy::DNS::Ovh.new(config, env)
    ovh.credentials_present?.should be_false
  end

  it "registrar_name retourne OVH" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    ovh = Deploy::DNS::Ovh.new(config, env)
    ovh.registrar_name.should eq("OVH")
  end

  it "load_credentials lit depuis les variables d'environnement" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    ovh = Deploy::DNS::Ovh.new(config, env)

    ENV["OVH_APP_KEY"] = "test_app_key"
    ENV["OVH_APP_SECRET"] = "test_app_secret"
    ENV["OVH_CONSUMER_KEY"] = "test_consumer_key"

    ovh.load_credentials
    ovh.credentials_present?.should be_true

    ENV.delete("OVH_APP_KEY")
    ENV.delete("OVH_APP_SECRET")
    ENV.delete("OVH_CONSUMER_KEY")
  end

  # Régression : la signature OVH utilisait HMAC-SHA1 (OpenSSL::HMAC.hexdigest)
  # alors que l'API OVH attend un SHA1 simple sur la chaîne concaténée.
  # Référence : table-de-gaya/config/deploy.sh, fonction ovh_sign() :
  #   printf '%s+%s+%s+%s+%s+%s' secret ck method url body ts
  #     | openssl dgst -sha1 -hex | awk '{print $2}'
  it "sign produit un SHA1 simple identique à openssl dgst -sha1 (pas HMAC)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    ovh = Deploy::DNS::Ovh.new(config, env)

    secret = "test_secret"
    consumer = "test_ck"
    method = "GET"
    url = "https://eu.api.ovh.com/1.0/test"
    body = ""
    ts = "1234567890"

    # Hash attendu calculé indépendamment via le shell :
    # printf '%s' "test_secret+test_ck+GET+https://eu.api.ovh.com/1.0/test++1234567890"
    #   | openssl dgst -sha1 -hex | awk '{print $NF}'
    expected = "3406dc26269a79ac617cd8befe0adef214580a47"

    result = ovh.sign_public(secret, consumer, method, url, body, ts)
    result.should eq(expected)
  end
end

describe Deploy::DNS::Factory do
  it "instancie DNS::Ovh pour registrar=ovh" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    dns = Deploy::DNS::Factory.for("ovh", config, env)
    dns.should be_a(Deploy::DNS::Ovh)
  end

  it "retourne nil si registrar est nil" do
    config = SpecHelper.kemal_config
    env = SpecHelper.dev_env(config)
    dns = Deploy::DNS::Factory.for(nil, config, env)
    dns.should be_nil
  end
end
