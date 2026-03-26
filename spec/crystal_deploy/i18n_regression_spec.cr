require "../spec_helper"

# ---------------------------------------------------------------------------
# Tests de non-régression I18n — clés ajoutées suite aux bugs rencontrés
# ---------------------------------------------------------------------------

describe CrystalDeploy::I18n, "non-régression DB_POOL_SIZE" do
  before_each do
    CrystalDeploy::I18n.reset
    CrystalDeploy::I18n.locales_dir = File.join(__DIR__, "..", "..", "locales")
  end

  # Régression : DB_POOL_SIZE n'avait pas de clé de traduction.
  # Le dialogue PostgreSQL posait la question sans label traduit.
  # Correction : ajout de db.pool_size_prompt dans toutes les locales.
  {% for lang in ["fr", "en", "es", "de", "pt", "it", "nl"] %}
    it "traduit db.pool_size_prompt en {{ lang.id }}" do
      CrystalDeploy::I18n.lang = {{ lang }}
      result = CrystalDeploy::I18n.t("db.pool_size_prompt")
      result.should_not eq("db.pool_size_prompt")
      result.should_not be_empty
    end
  {% end %}
end

describe CrystalDeploy::Config, "#effective_env_vars non-régression" do
  # Régression : DB_POOL_SIZE était dans DEFAULT_SKIP, ce qui l'excluait
  # du dialogue interactif. Il doit maintenant être posé dans le dialogue PG.
  it "DB_POOL_SIZE n'est PAS dans DEFAULT_SKIP" do
    config = SpecHelper.marten_config
    rules = config.effective_env_vars
    rules.skip.should_not contain("DB_POOL_SIZE")
  end

  # APP_HOST et APP_PORT doivent rester dans DEFAULT_SKIP car ils sont
  # injectés automatiquement par inject_marten_vars.
  it "APP_HOST est dans DEFAULT_SKIP (injecté automatiquement)" do
    config = SpecHelper.marten_config
    rules = config.effective_env_vars
    rules.skip.should contain("APP_HOST")
  end

  it "APP_PORT est dans DEFAULT_SKIP (injecté automatiquement)" do
    config = SpecHelper.marten_config
    rules = config.effective_env_vars
    rules.skip.should contain("APP_PORT")
  end
end
