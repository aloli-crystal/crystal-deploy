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
