require "../../spec_helper"

describe Deploy::DB::Factory do
  it "instancie DB::Sqlite pour database=sqlite" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = Deploy::DB::Factory.for("sqlite", config, env)
    db.should be_a(Deploy::DB::Sqlite)
  end
end

describe Deploy::DB::Sqlite do
  it "est une sous-classe de DB::Base" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    db = Deploy::DB::Sqlite.new(config, env)
    db.should be_a(Deploy::DB::Base)
  end
end
