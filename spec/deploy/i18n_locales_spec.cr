require "../spec_helper"

# Tests de couverture des nouvelles locales (es, de, pt, it, nl)
# Vérifie que chaque locale charge correctement et traduit les clés essentielles.
describe Deploy::I18n, "nouvelles locales" do
  before_each do
    Deploy::I18n.reset
    Deploy::I18n.locales_dir = File.join(__DIR__, "..", "..", "locales")
  end

  {% for lang, label in {"es" => "espagnol", "de" => "allemand", "pt" => "portugais", "it" => "italien", "nl" => "néerlandais"} %}
    describe {{ lang }} do
      it "traduit db.section en {{ lang.id }}" do
        Deploy::I18n.lang = {{ lang }}
        result = Deploy::I18n.t("db.section")
        result.should_not eq("db.section")
        result.should_not be_empty
      end

      it "traduit errors.unknown_env avec interpolation en {{ lang.id }}" do
        Deploy::I18n.lang = {{ lang }}
        result = Deploy::I18n.t("errors.unknown_env", name: "staging")
        result.should_not eq("errors.unknown_env")
        result.should contain("staging")
      end

      it "traduit dns.section en {{ lang.id }}" do
        Deploy::I18n.lang = {{ lang }}
        result = Deploy::I18n.t("dns.section")
        result.should_not eq("dns.section")
        result.should_not be_empty
      end

      it "traduit init.required_empty en {{ lang.id }}" do
        Deploy::I18n.lang = {{ lang }}
        result = Deploy::I18n.t("init.required_empty")
        result.should_not eq("init.required_empty")
        result.should_not be_empty
      end

      it "traduit db.sqlite_path_prompt en {{ lang.id }}" do
        Deploy::I18n.lang = {{ lang }}
        result = Deploy::I18n.t("db.sqlite_path_prompt")
        result.should_not eq("db.sqlite_path_prompt")
        result.should_not be_empty
      end

      it "traduit dns.key_pat en {{ lang.id }}" do
        Deploy::I18n.lang = {{ lang }}
        result = Deploy::I18n.t("dns.key_pat")
        result.should_not eq("dns.key_pat")
        result.should_not be_empty
      end
    end
  {% end %}
end
