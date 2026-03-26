require "../spec_helper"

# ---------------------------------------------------------------------------
# Tests de non-régression sur le script shell généré par RemoteScript
# ---------------------------------------------------------------------------

describe CrystalDeploy::SSH::RemoteScript, "non-régression" do
  # Régression : sudo su -m utilisait le shell de l'utilisateur (zsh sur le serveur).
  # De plus, set -a sur FreeBSD /bin/sh exporte aussi les variables héritées dont
  # les noms commencent par '_' ou d'autres caractères non-alphabétiques, ce qui
  # lève "Nom de variable incorrect".
  # Correction : script wrapper avec 'export KEY=VALUE' ligne par ligne.
  it "run_with_env utilise un script wrapper avec export (pas set -a)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Utilise un script wrapper execute directement par /bin/sh
    content.should contain("_RWE_WRAPPER")
    content.should contain("export %s")
    content.should contain("/bin/sh \"${_RWE_WRAPPER}\"")
    # Ne doit PAS utiliser set -a (cause de l'erreur sur FreeBSD)
    content.should_not contain("set -a")
  end

  # Le script wrapper doit etre executable par APP_USER (chmod 755)
  it "run_with_env utilise chmod 755 sur le script wrapper" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("chmod 755")
  end

  # Les commentaires et lignes vides du .env doivent etre filtres
  # pour ne pas generer des lignes 'export # commentaire' dans le wrapper.
  it "run_with_env filtre les commentaires et lignes vides du .env" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("grep -v '^[[:space:]]*#'")
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
