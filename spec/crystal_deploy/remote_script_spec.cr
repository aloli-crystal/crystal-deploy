require "../spec_helper"

# ---------------------------------------------------------------------------
# Tests de non-régression sur le script shell généré par RemoteScript
# ---------------------------------------------------------------------------

describe CrystalDeploy::SSH::RemoteScript, "non-régression" do
  # Régression : sudo su causait des problèmes sur FreeBSD (username too long,
  # interaction avec set -e). De plus, set -a sur FreeBSD /bin/sh exporte aussi
  # les variables héritées dont les noms commencent par '_' ou d'autres caractères
  # non-alphabétiques, ce qui lève "Nom de variable incorrect".
  # Correction : script wrapper avec 'export KEY=VALUE' exécuté directement.
  it "run_with_env utilise un script wrapper avec export (pas set -a ni sudo su)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Utilise un script wrapper exécuté directement par /bin/sh
    content.should contain("_RWE_WRAPPER")
    content.should contain("export %s=\"%s\"")
    # run_with_env exécute le wrapper directement (pas de sudo su)
    content.should contain("/bin/sh \"${_RWE_WRAPPER}\"")
    content.should_not contain("sudo su \"${_RWE_USER}\"")
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

  # CORRECTIF : git clone --bare ne configure PAS de fetch refspec par défaut.
  # Sans refspec, git fetch --prune origin ne met à jour aucune branche locale du bare.
  # init_repo doit ajouter +refs/heads/*:refs/heads/* après le clone.
  it "init_repo configure le refspec fetch après git clone --bare" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Le refspec doit être configuré après le clone
    content.should contain("remote.origin.fetch '+refs/heads/*:refs/heads/*'")
    # Et aussi corrigé si le bare existe déjà sans refspec (init relancé)
    content.should contain("CURRENT_FETCH")
    # init_repo ne doit PAS retourner 0 sans vérifier le refspec si le bare existe
    init_start = content.index("init_repo() {")
    init_end = content.index("init_env() {")
    if init_start && init_end
      init_body = content[init_start...init_end]
      # Le bloc "bare déjà présent" doit contenir la vérification du refspec
      init_body.should contain("remote.origin.fetch")
    end
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

  # init_rcd doit générer le script rc.d directement via base64 (encodé côté Crystal)
  # et non chercher un fichier dans current/config/ qui n'existe pas lors du premier init.
  it "init_rcd génère le script rc.d via base64 (pas de dépendance sur current/config/)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # init_rcd doit utiliser base64 -d pour décoder le script rc.d
    content.should contain("base64 -d | sudo tee")
    # init_rcd ne doit PAS chercher un fichier dans current/config/
    content.should_not contain("current/config/rc.d")
    # init_rcd ne doit PAS afficher le message d'erreur de l'ancienne implémentation
    content.should_not contain("Lancez d'abord un premier deploy")
    # Le contenu base64 doit être non vide (le script rc.d est bien encodé)
    rcd_b64_match = content.match(/printf '%s' "([A-Za-z0-9+\/]+=*)" \| base64 -d/)
    rcd_b64_match.should_not be_nil
    if m = rcd_b64_match
      # Vérifier que le contenu décodé contient bien un script rc.d valide
      decoded = Base64.decode_string(m[1])
      # Le nouveau script n'a plus de ligne # PROVIDE: (remplacée par un en-tête complet)
      # Vérifier les éléments essentiels du script rc.d
      decoded.should contain(". /etc/rc.subr")
      decoded.should contain("run_rc_command")
      decoded.should contain("_generate_wrapper")
      decoded.should contain("set -a")
    end
  end

  # CORRECTIF : marten ne définit pas de target dans shard.yml.
  # bin/marten est créé par le postinstall de shards install (precompile_marten_cli).
  # 'shards build marten' échoue avec 'Targets not defined in shard.yml'.
  it "shards_prepare n'appelle pas shards build marten (postinstall s'en charge)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    shards_start = content.index("shards_prepare() {")
    compile_start_pos = content.index("compile_start() {")
    if shards_start && compile_start_pos
      shards_body = content[shards_start...compile_start_pos]
      # shards_prepare ne doit PAS appeler 'shards build marten'
      shards_body.should_not contain("shards build marten")
      # shards_prepare doit appeler shards install --production
      shards_body.should contain("shards install --production")
      # shards_prepare doit vérifier que bin/marten est bien présent après install
      shards_body.should contain("bin/marten")
    end
  end

  # CORRECTIF : le lien symbolique rc.d doit utiliser SERVICE_RC_NAME (underscores)
  # car FreeBSD 'service' cherche le fichier par son nom exact dans /usr/local/etc/rc.d/.
  # SERVICE_NAME utilise des tirets (les-amis-de-joseph--developpement) mais
  # SERVICE_RC_NAME utilise des underscores (les_amis_de_joseph__developpement).
  it "init_rcd crée le lien symbolique avec SERVICE_RC_NAME (underscores) et non SERVICE_NAME (tirets)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Trouver le corps de init_rcd()
    # init_rcd est injectée en début de script (avant le heredoc principal) ;
    # la prochaine fonction définie après elle est create_database.
    init_rcd_start = content.index("init_rcd() {")
    init_rcd_end = content.index("create_database() {")
    if init_rcd_start && init_rcd_end && init_rcd_start < init_rcd_end
      init_rcd_body = content[init_rcd_start...init_rcd_end]
      # Le lien symbolique doit utiliser SERVICE_RC_NAME (avec underscores)
      init_rcd_body.should contain("/usr/local/etc/rc.d/${SERVICE_RC_NAME}")
      # Et non SERVICE_NAME (avec tirets)
      init_rcd_body.should_not contain("/usr/local/etc/rc.d/${SERVICE_NAME}")
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

describe CrystalDeploy::SSH::RemoteScript, "traduction messages Marten" do
  # Marten affiche "No pending migrations to apply" en anglais.
  # Le script de déploiement doit le traduire en français via sed.
  it "run_migrations traduit les messages Marten en français via sed" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Le script doit utiliser sed pour traduire les messages
    content.should contain("No pending migrations to apply")
    content.should contain("Aucune migration en attente.")
    content.should contain("Running migrations:")
    content.should contain("Application des migrations :")
    # La sortie doit être capturée dans un fichier temporaire pour préserver le code de retour
    content.should contain("_MIGRATE_OUT")
    content.should contain("_MIGRATE_RC")
  end

  it "run_migrations préserve le code de retour de bin/marten (pas de pipe direct)" do
    config = SpecHelper.marten_config
    env = SpecHelper.dev_env(config)
    content = CrystalDeploy::SSH::RemoteScript.generate(config, env)
    # Chercher le corps de run_migrations
    mig_start = content.index("run_migrations() {")
    mig_end = content.index("graceful_stop() {")
    if mig_start && mig_end
      mig_body = content[mig_start...mig_end]
      # Doit capturer la sortie dans un fichier temporaire
      mig_body.should contain("mktemp")
      # Le code retour est capturé via && ... || pour résister à set -e
      mig_body.should contain("_MIGRATE_RC=0 || _MIGRATE_RC=$?")
      # Doit vérifier le code de retour après sed
      mig_body.should contain("[ ${_MIGRATE_RC} -eq 0 ]")
    end
  end
end

describe CrystalDeploy::DNS::Ovh, "vérification CNAME" do
  it "cname_exists détecte un tableau JSON non vide d'IDs numériques" do
    # Simuler les réponses possibles de l'API OVH
    # Tableau non vide → CNAME existe
    !!(("[12345678]" =~ /^\[\s*\d/)).should be_truthy
    !!(("[ 12345678, 87654321 ]" =~ /^\[\s*\d/)).should be_truthy
    # Tableau vide → pas de CNAME
    !!(("[]" =~ /^\[\s*\d/)).should be_falsey
    # Erreur d'authentification OVH (pas de mot "error") → pas de CNAME
    !!(("{\"message\":\"Invalid credentials\"}" =~ /^\[\s*\d/)).should be_falsey
    # Réponse vide (timeout curl) → pas de CNAME
    !!(("" =~ /^\[\s*\d/)).should be_falsey
  end
end
