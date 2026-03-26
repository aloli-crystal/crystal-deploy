require "../../spec_helper"

describe CrystalDeploy::DB::Factory do
  it "instancie DB::Sqlite pour database=sqlite" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Factory.for("sqlite", config, env)
    db.should be_a(CrystalDeploy::DB::Sqlite)
  end
end

describe CrystalDeploy::DB::Sqlite do
  it "est une sous-classe de DB::Base" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Sqlite.new(config, env)
    db.should be_a(CrystalDeploy::DB::Base)
  end
end
