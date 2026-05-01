require "../spec_helper"

describe Deploy::CLI do
  describe ".resolve_command" do
    it "renvoie `deploy` quand la liste est vide" do
      Deploy::CLI.resolve_command([] of String).should eq "deploy"
    end

    it "renvoie `deploy` quand seul un flag --<env> est passé" do
      Deploy::CLI.resolve_command(["--production"]).should eq "deploy"
      Deploy::CLI.resolve_command(["--prod"]).should eq "deploy"
      Deploy::CLI.resolve_command(["--developpement"]).should eq "deploy"
    end

    it "renvoie la commande explicite quand elle est présente" do
      Deploy::CLI.resolve_command(["init"]).should eq "init"
      Deploy::CLI.resolve_command(["init", "--production"]).should eq "init"
      Deploy::CLI.resolve_command(["status", "--prep"]).should eq "status"
      Deploy::CLI.resolve_command(["rollback"]).should eq "rollback"
    end

    it "ignore les flags placés avant la commande" do
      Deploy::CLI.resolve_command(["--production", "init"]).should eq "init"
      Deploy::CLI.resolve_command(["--prod", "rollback"]).should eq "rollback"
    end
  end
end
