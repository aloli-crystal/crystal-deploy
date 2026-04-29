require "../spec_helper"

describe Deploy::EnvParser do
  it "parse les paires clé=valeur simples" do
    content = "KEY=value\nDB_HOST=localhost"
    result = Deploy::EnvParser.parse(content)
    result.should eq [{"KEY", "value"}, {"DB_HOST", "localhost"}]
  end

  it "ignore les commentaires et lignes vides" do
    content = "# Commentaire\nKEY=value\n\n  # Autre commentaire\nKEY2=value2"
    result = Deploy::EnvParser.parse(content)
    result.should eq [{"KEY", "value"}, {"KEY2", "value2"}]
  end

  it "retire les guillemets doubles englobants" do
    result = Deploy::EnvParser.parse(%(KEY="value with spaces"))
    result.should eq [{"KEY", "value with spaces"}]
  end

  it "retire les guillemets simples englobants" do
    result = Deploy::EnvParser.parse("KEY='value with spaces'")
    result.should eq [{"KEY", "value with spaces"}]
  end

  it "préserve les = dans les valeurs (URLs)" do
    result = Deploy::EnvParser.parse("DATABASE_URL=postgres://user:pass@host/db?opt=1")
    result.should eq [{"DATABASE_URL", "postgres://user:pass@host/db?opt=1"}]
  end

  it "génère des exports correctement échappés" do
    content = "SIMPLE=hello\nPASS=p@ss)w0rd\nQUOTED=\"already quoted\"\nDOLLAR=price$5\nBACKTICK=val`cmd"
    exports = Deploy::EnvParser.generate_exports(content)
    exports.should contain("export SIMPLE=\"hello\"")
    exports.should contain("export PASS=\"p@ss)w0rd\"")
    exports.should contain("export QUOTED=\"already quoted\"")
    exports.should contain("export DOLLAR=\"price\\$5\"")
    exports.should contain("export BACKTICK=\"val\\`cmd\"")
  end

  it "échappe les guillemets doubles dans les valeurs" do
    exports = Deploy::EnvParser.generate_exports("KEY=val\"ue")
    exports.should contain("export KEY=\"val\\\"ue\"")
  end

  it "échappe les backslashes dans les valeurs" do
    exports = Deploy::EnvParser.generate_exports("KEY=val\\ue")
    exports.should contain("export KEY=\"val\\\\ue\"")
  end
end
