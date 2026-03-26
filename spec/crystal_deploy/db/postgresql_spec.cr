require "../../spec_helper"

describe CrystalDeploy::DB::Factory do
  it "instancie DB::Postgresql pour database=postgresql" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Factory.for("postgresql", config, env)
    db.should be_a(CrystalDeploy::DB::Postgresql)
  end

  it "instancie DB::None pour database=none" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Factory.for("none", config, env)
    db.should be_a(CrystalDeploy::DB::None)
  end

  it "instancie DB::None pour database vide" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Factory.for("", config, env)
    db.should be_a(CrystalDeploy::DB::None)
  end

  it "DB::None#run_dialog retourne un hash vide" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::None.new(config, env)
    db.run_dialog.should be_empty
  end
end

# ---------------------------------------------------------------------------
# Tests de non-régression — bugs rencontrés en production
# ---------------------------------------------------------------------------

describe CrystalDeploy::DB::Postgresql, "non-régression" do
  # Régression : DB_PORT était vide ("") pour les connexions socket Unix avec Marten.
  # Marten lève KeyError: "DB_PORT" si la variable est absente ou vide.
  # Correction : DB_PORT doit toujours valoir "5432" (même pour socket Unix).
  it "socket Unix Marten : DB_PORT vaut 5432 (non vide)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Postgresql.new(config, env)
    result = db.socket_vars_for_test("/tmp", "user", "pass", "db", "10")
    result["DB_PORT"].should eq("5432")
    result["DB_PORT"].should_not be_empty
  end

  # Régression : DB_HOST était absent du hash socket Unix pour Marten.
  # Le driver pg de Crystal interprète DB_HOST comme répertoire de socket
  # quand il commence par '/'.
  it "socket Unix Marten : DB_HOST contient le répertoire du socket" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Postgresql.new(config, env)
    result = db.socket_vars_for_test("/tmp", "user", "pass", "db", "10")
    result["DB_HOST"].should eq("/tmp")
  end

  # Régression : DB_POOL_SIZE n'était pas inclus dans les variables générées.
  # Il était injecté automatiquement dans inject_marten_vars avec la valeur "10",
  # ce qui contournait le dialogue PostgreSQL.
  # Correction : DB_POOL_SIZE est demandé dans le dialogue PG et inclus dans le hash.
  it "socket Unix Marten : DB_POOL_SIZE est inclus dans les variables" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Postgresql.new(config, env)
    result = db.socket_vars_for_test("/tmp", "user", "pass", "db", "10")
    result.has_key?("DB_POOL_SIZE").should be_true
    result["DB_POOL_SIZE"].should eq("10")
  end

  # Régression : DB_POOL_SIZE n'était pas inclus pour TCP non plus.
  it "TCP Marten : DB_POOL_SIZE est inclus dans les variables" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Postgresql.new(config, env)
    result = db.tcp_vars_for_test("localhost", "user", "pass", "db", "10")
    result.has_key?("DB_POOL_SIZE").should be_true
    result["DB_POOL_SIZE"].should eq("10")
  end

  # Régression : Kemal utilisait DB_HOST/DB_PORT au lieu de DATABASE_URL pour socket Unix.
  # Le driver pg de Crystal ne supporte pas DB_HOST=/tmp — il faut DATABASE_URL.
  it "socket Unix Kemal : retourne DATABASE_URL (pas DB_HOST)" do
    config = SpecHelper.kemal_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Postgresql.new(config, env)
    result = db.socket_vars_for_test("/tmp", "user", "pass", "db", "10")
    result.has_key?("DATABASE_URL").should be_true
    result.has_key?("DB_HOST").should be_false
  end
end
