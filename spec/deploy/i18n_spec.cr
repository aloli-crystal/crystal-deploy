require "../spec_helper"

describe Deploy::I18n do
  before_each do
    Deploy::I18n.reset
    Deploy::I18n.locales_dir = File.join(__DIR__, "..", "..", "locales")
  end

  describe "détection de la langue" do
    it "détecte fr depuis LANG=fr_FR.UTF-8" do
      old = ENV["LANG"]?
      ENV["LANG"] = "fr_FR.UTF-8"
      Deploy::I18n.reset
      Deploy::I18n.lang.should eq("fr")
      ENV["LANG"] = old || ""
    end

    it "retourne en si LANG est absent" do
      old = ENV["LANG"]?
      ENV.delete("LANG")
      Deploy::I18n.reset
      Deploy::I18n.lang.should eq("en")
      ENV["LANG"] = old if old
    end

    it "retourne en si LANG=C" do
      old = ENV["LANG"]?
      ENV["LANG"] = "C"
      Deploy::I18n.reset
      Deploy::I18n.lang.should eq("en")
      ENV["LANG"] = old || ""
    end
  end

  describe "traduction" do
    it "traduit une clé en français" do
      Deploy::I18n.lang = "fr"
      result = Deploy::I18n.t("db.section")
      result.should eq("Base de données")
    end

    it "traduit une clé en anglais" do
      Deploy::I18n.lang = "en"
      result = Deploy::I18n.t("db.section")
      result.should eq("Database")
    end

    it "interpole les arguments nommés" do
      Deploy::I18n.lang = "fr"
      result = Deploy::I18n.t("errors.unknown_env", name: "staging")
      result.should eq("Environnement inconnu : staging")
    end

    it "retourne la clé brute si absente dans les deux langues" do
      Deploy::I18n.lang = "fr"
      result = Deploy::I18n.t("cle.inexistante")
      result.should eq("cle.inexistante")
    end

    it "fait le fallback sur l'anglais si la langue n'a pas de fichier de locale" do
      # Utiliser une langue sans fichier de locale (xx n'existe pas)
      Deploy::I18n.lang = "xx"
      result = Deploy::I18n.t("db.section")
      result.should eq("Database")
    end
  end
end
