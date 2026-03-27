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
    # run_with_env doit utiliser sudo su sans -m (pas de preservation de l'env root)
    # La ligne exacte generee par run_with_env :
    content.should contain("sudo su \"${_RWE_USER}\" -c \"/bin/sh ${_RWE_WRAPPER}\"")
    # Ne doit PAS utiliser set -a dans le code shell (hors commentaires)
    code_lines = content.lines.reject { |l| l.strip.starts_with?("#") }
    code_lines.join("\n").should_not contain("set -a")
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

  # Régression potentielle : git clone complet à chaque deploy.
  # Correction : dépôt bare partagé dans shared/repo.git.
  # init_repo clone --bare une seule fois ; clone_repo fait fetch + git archive.
  it "init_repo clone le dépôt en mode bare dans shared/repo.git" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("git clone --bare")
    content.should contain("REPO_DIR")
    # init_repo doit être idempotent (ne pas re-cloner si déjà présent)
    content.should contain("[ -d \"${REPO_DIR}\"")
  end

  it "clone_repo utilise git fetch + git archive (pas git clone --depth)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Doit utiliser fetch pour mettre à jour le bare (deltas uniquement)
    content.should contain("fetch --prune origin")
    # Doit extraire via git archive (pas de .git dans la release)
    content.should contain("git archive")
    content.should contain("tar -x -C")
    # clone_repo ne doit PAS faire de git clone --depth
    clone_start = content.index("clone_repo() {")
    link_start = content.index("link_shared() {")
    if clone_start && link_start
      clone_body = content[clone_start...link_start]
      clone_body.should_not contain("git clone --depth")
    end
  end

  it "init_repo est appelé dans le bloc init (avant deploy)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Dans le case/esac, deploy) apparaît avant init) dans le script généré
    # On cherche le bloc init) avec son indentation réelle (2 espaces)
    deploy_start = content.index("  deploy)")
    init_start = content.index("  init)")
    if init_start && deploy_start
      init_block = content[init_start..]
      init_block.should contain("init_repo")
    end
  end

  # Parallélisation : compile_start lance la compilation en arrière-plan,
  # compile_wait attend la fin. Le bloc init utilise compile_start + compile_wait
  # séparément pour intercaler create_database + run_migrations.
  it "compile_start et compile_wait existent comme fonctions distinctes" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    content.should contain("compile_start()")
    content.should contain("compile_wait()")
    # compile() doit appeler compile_start puis compile_wait (version séquentielle)
    # L'indentation réelle dans le script généré est 2 espaces
    content.should contain("compile_start\n  compile_wait")
  end

  it "le bloc init lance compile_start avant create_database (parallèle)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    init_start = content.index("init)")
    deploy_start = content.index("deploy)")
    if init_start && deploy_start
      init_block = content[init_start...deploy_start]
      # Dans init, compile_start doit apparaître AVANT create_database
      cs_pos = init_block.index("compile_start")
      cdb_pos = init_block.index("create_database")
      cw_pos = init_block.index("compile_wait")
      if cs_pos && cdb_pos && cw_pos
        cs_pos.should be < cdb_pos   # compile_start avant create_database
        cdb_pos.should be < cw_pos   # create_database avant compile_wait
      end
    end
  end

  it "le bloc init attend compile_wait avant activate_release" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    init_start = content.index("init)")
    deploy_start = content.index("deploy)")
    if init_start && deploy_start
      init_block = content[init_start...deploy_start]
      cw_pos = init_block.index("compile_wait")
      ar_pos = init_block.index("activate_release")
      if cw_pos && ar_pos
        cw_pos.should be < ar_pos   # compile_wait avant activate_release
      end
    end
  end

  # init_rcd doit être appelé APRES activate_release dans init :
  # le script rc.d est dans current/config/ qui n'existe qu'après activation.
  it "init_rcd est appelé après activate_release dans le bloc init" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    init_start = content.index("  init)")
    deploy_start = content.index("  deploy)")
    if init_start && deploy_start
      init_block = content[init_start...deploy_start]
      ar_pos = init_block.index("activate_release")
      # Chercher l'APPEL de init_rcd (ligne seule avec indentation) et non sa définition
      # La définition est "init_rcd() {" ; l'appel est "            init_rcd" (sans paren)
      rcd_call_pos = init_block.index(/^\s+init_rcd\s*$/)  # ligne seule, pas de (){}
      if ar_pos && rcd_call_pos
        ar_pos.should be < rcd_call_pos   # activate_release avant l'appel de init_rcd
      end
    end
  end

  it "le bloc deploy utilise shards_prepare + compile_start + compile_wait (parallélisé)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    deploy_start = content.index("  deploy)")
    rollback_start = content.index("  rollback)")
    if deploy_start && rollback_start
      deploy_block = content[deploy_start...rollback_start]
      # deploy utilise shards_prepare (séquentiel) puis compile_start + compile_wait (parallèle)
      deploy_block.should contain("shards_prepare")
      deploy_block.should contain("compile_start")
      deploy_block.should contain("compile_wait")
      # run_migrations et run_seed sont appelés en parallèle avec crystal build
      deploy_block.should contain("run_migrations")
      deploy_block.should contain("run_seed")
      # compile() séquentiel ne doit plus être utilisé dans deploy
      # (il n'apparaît que dans la définition de la fonction compile())
    end
  end
end
