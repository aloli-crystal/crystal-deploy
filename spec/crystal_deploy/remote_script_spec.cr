require "../spec_helper"

# ---------------------------------------------------------------------------
# Tests de non-régression sur le script shell généré par RemoteScript
# ---------------------------------------------------------------------------

describe CrystalDeploy::SSH::RemoteScript, "non-régression" do
  # Régression : run_with_env créait le fichier temporaire avec chmod 600.
  # APP_USER (ex: deploy) ne pouvait pas le lire → le sourçage échouait
  # silencieusement → "set: Le nom de la variable doit commencer par une lettre".
  # Correction : chmod 644 pour que APP_USER puisse lire le fichier.
  it "run_with_env utilise chmod 644 (non 600) sur le .env temporaire" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("chmod 644")
    content.should_not match(/chmod 600.*_RWE_TMP|_RWE_TMP.*chmod 600/)
  end

  # Régression : run_with_env ne filtrait pas les commentaires du .env.
  # /bin/sh (FreeBSD) lève une erreur sur les lignes commençant par '#'.
  # Correction : grep -v '^[[:space:]]*#' filtre les commentaires avant sourçage.
  it "run_with_env filtre les commentaires du .env avant sourçage" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("grep -v '^[[:space:]]*#'")
  end

  # Régression : run_with_env ne filtrait pas les lignes vides du .env.
  # /bin/sh peut lever des erreurs sur les lignes vides avec set -a.
  it "run_with_env filtre les lignes vides du .env avant sourçage" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("grep -v '^[[:space:]]*$'")
  end

  # Régression : run_migrations utilisait ./bin/${APP_FULL_NAME} migrate.
  # Le binaire applicatif ne définit pas de commande CLI 'migrate' —
  # il démarre le serveur web par défaut quand il reçoit un argument inconnu.
  # Correction : utiliser ./bin/marten migrate (le binaire Marten lui-même).
  it "run_migrations utilise bin/marten migrate (pas le binaire applicatif)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("./bin/marten migrate")
    # Le binaire applicatif ne doit PAS être utilisé pour les migrations
    content.should_not match(/\.\/bin\/test-app--developpement migrate/)
  end

  # Régression : shards install --production échouait si shard.lock était
  # obsolète (source changée via shard.override.yml).
  # Correction : fallback automatique vers shards update --production.
  it "compile utilise shards update en fallback si shards install échoue" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("shards install --production")
    content.should contain("shards update --production")
    # Le fallback doit être enchaîné avec || (ou logique)
    content.should match(/shards install --production.*\|\|.*shards update --production/m)
  end
end
