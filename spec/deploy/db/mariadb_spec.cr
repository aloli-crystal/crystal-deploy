require "../../spec_helper"

describe Deploy::DB::Factory do
  it "instancie DB::Mariadb pour database=mariadb" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = Deploy::DB::Factory.for("mariadb", config, env)
    db.should be_a(Deploy::DB::Mariadb)
  end

  it "instancie DB::Mariadb pour database=mysql" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = Deploy::DB::Factory.for("mysql", config, env)
    db.should be_a(Deploy::DB::Mariadb)
  end
end

describe Deploy::DB::Mariadb do
  it "est une sous-classe de DB::Base" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = Deploy::DB::Mariadb.new(config, env)
    db.should be_a(Deploy::DB::Base)
  end
end
