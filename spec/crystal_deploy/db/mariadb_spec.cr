require "../../spec_helper"

describe CrystalDeploy::DB::Factory do
  it "instancie DB::Mariadb pour database=mariadb" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Factory.for("mariadb", config, env)
    db.should be_a(CrystalDeploy::DB::Mariadb)
  end

  it "instancie DB::Mariadb pour database=mysql" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Factory.for("mysql", config, env)
    db.should be_a(CrystalDeploy::DB::Mariadb)
  end
end

describe CrystalDeploy::DB::Mariadb do
  it "est une sous-classe de DB::Base" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = CrystalDeploy::DB::Mariadb.new(config, env)
    db.should be_a(CrystalDeploy::DB::Base)
  end
end
