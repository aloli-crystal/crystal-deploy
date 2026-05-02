module Deploy
  module SSH
    # Génère le script shell POSIX exécuté sur le serveur distant.
    # Ce script est auto-contenu : il reçoit tous ses paramètres en arguments
    # et n'a pas besoin du shard Crystal côté serveur.
    #
    # Le paramètre FRAMEWORK (marten | kemal) adapte :
    #   - La lecture des variables .env (APP_URL+UNIX_SOCKET vs MARTEN_ALLOWED_HOSTS+MARTEN_SOCKET)
    #   - Les alias statiques NGINX (public/assets/ vs public/css|js|images|vendor/)
    #   - Les migrations (marten migrate vs schema_pg.sql)
    #   - Le seed (marten manage seed vs ./bin/<app> seed)
    module RemoteScript
      # Génère la fonction shell init_rcd avec le script rc.d encodé en base64.
      # On utilise une méthode séparée pour pouvoir interpoler rcd_b64 dans la string
      # sans casser le heredoc principal <<-'SHELL_EOF' (qui n'accepte pas l'interpolation).
      private def self.init_rcd_function(rcd_b64 : String) : String
        <<-FUNC
        init_rcd() {
          log_section "Script rc.d"
          RCD_SHARED="${SHARED_DIR}/rc.d.${SERVICE_RC_NAME}"
          RCD_LINK="/usr/local/etc/rc.d/${SERVICE_RC_NAME}"
          # Générer le script rc.d depuis le contenu encodé en base64
          # (contenu généré par deploy lors de la création du script de déploiement)
          printf '%s' "#{rcd_b64}" | base64 -d | sudo tee "${RCD_SHARED}" >/dev/null
          sudo chmod 755 "${RCD_SHARED}"
          sudo chown root:wheel "${RCD_SHARED}"
          log_info "Script rc.d généré : ${RCD_SHARED}"
          sudo rm -f "${RCD_LINK}"
          sudo ln -s "${RCD_SHARED}" "${RCD_LINK}"
          log_info "Lien symbolique créé : ${RCD_LINK} → ${RCD_SHARED}"
          if ! grep -q "${SERVICE_RC_NAME}_enable" /etc/rc.conf 2>/dev/null; then
            printf "\\n# ${APP_FULL_NAME} — ajouté par deploy le %s\\n" "$(date)" \\
              | sudo tee -a /etc/rc.conf >/dev/null
            printf '%s_enable="YES"\\n' "${SERVICE_RC_NAME}" | sudo tee -a /etc/rc.conf >/dev/null
            log_info "Ligne ajoutée dans /etc/rc.conf."
          else
            log_info "${SERVICE_RC_NAME}_enable déjà présent dans /etc/rc.conf."
          fi
        }
        FUNC
      end

      def self.generate(config : Config, env : Environment) : String
        rcd_generator = Generators::Rcd.new(config, env)
        nginx_generator = Generators::Nginx.new(config, env)
        # Encoder le script rc.d en base64 pour l'injecter sans problème d'échappement
        # (le contenu contient des apostrophes dans les commentaires français)
        rcd_b64 = Base64.strict_encode(rcd_generator.generate)

        <<-'SHELL_EOF' +
        #!/bin/sh
        # Script généré automatiquement par deploy
        # Ne pas modifier manuellement.
        set -e

        # --- Arguments ---
        # $1 = --remote (marqueur)
        # $2 = ENV_NAME, $3 = APP_NAME, $4 = BRANCH, $5 = REPO_URL
        # $6 = CRYSTAL_MAIN, $7 = CRYSTAL_FLAGS, $8 = KEEP_RELEASES
        # $9 = COMMAND, $10 = DATA_FILE (chemin vers le fichier de données), $11 = FRAMEWORK
        # $12 = SEED_ENABLED ("true" / "false") — si "false", run_seed est court-circuité.
        ENV_NAME="${2}"
        APP_NAME="${3}"
        REPO_BRANCH="${4}"
        REPO_URL="${5}"
        CRYSTAL_MAIN="${6}"
        CRYSTAL_FLAGS="${7}"
        KEEP_RELEASES="${8}"
        COMMAND="${9:-deploy}"
        DATA_FILE="${10:-}"
        FRAMEWORK="${11:-kemal}"
        SEED_ENABLED="${12:-true}"

        # Lire les données sensibles depuis le fichier de données (une valeur par ligne)
        # Cela évite tout problème d'échappement shell avec les caractères spéciaux du Base64
        if [ -f "${DATA_FILE}" ]; then
          ENV_B64=$(sed -n '1p' "${DATA_FILE}")
          PG_USER_B64=$(sed -n '2p' "${DATA_FILE}")
          PG_PASS_B64=$(sed -n '3p' "${DATA_FILE}")
          PG_DB_B64=$(sed -n '4p' "${DATA_FILE}")
          PG_HOST_B64=$(sed -n '5p' "${DATA_FILE}")
        else
          ENV_B64=""
          PG_USER_B64=""
          PG_PASS_B64=""
          PG_DB_B64=""
          PG_HOST_B64=""
        fi

        # --- Variables dérivées ---
        APP_FULL_NAME="${APP_NAME}--${ENV_NAME}"
        APP_USER="$(whoami)"
        APP_GROUP="www"
        APP_HOME="/home/${APP_FULL_NAME}"
        RELEASES_DIR="${APP_HOME}/releases"
        SHARED_DIR="${APP_HOME}/shared"
        CURRENT_LINK="${APP_HOME}/current"
        BIN_LINK="/usr/local/bin/${APP_FULL_NAME}"
        SERVICE_NAME="${APP_FULL_NAME}"
        SERVICE_RC_NAME=$(printf '%s' "${APP_FULL_NAME}" | tr '-' '_')
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        RELEASE_DIR="${RELEASES_DIR}/${TIMESTAMP}"
        GRACEFUL_TIMEOUT="${GRACEFUL_TIMEOUT:-30}"
        REPO_DIR="${SHARED_DIR}/repo.git"   # dépôt bare partagé entre toutes les releases

        # Verrou de déploiement : évite deux déploiements simultanés
        LOCKFILE="/tmp/.deploy-${APP_FULL_NAME}.lock"

        GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
        log_info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$1"; }
        log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
        log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }
        log_section() { printf "\n${GREEN}=== %s ===${NC}\n" "$1"; }

        check_sudo() {
          [ "$(id -u)" -eq 0 ] && { log_error "Ne pas exécuter en root direct."; exit 1; }
          command -v sudo >/dev/null 2>&1 || { log_error "sudo introuvable : pkg install sudo"; exit 1; }
          sudo -v 2>/dev/null || { log_error "Droits sudo insuffisants."; exit 1; }
        }

        # ---------------------------------------------------------------------------
        # Verrou de déploiement
        # Empêche deux déploiements simultanés (ex : deux pushes rapides sur CI).
        # ---------------------------------------------------------------------------
        acquire_lock() {
          if [ -f "${LOCKFILE}" ]; then
            LOCK_PID=$(cat "${LOCKFILE}" 2>/dev/null | tr -d '[:space:]')
            if [ -n "${LOCK_PID}" ] && kill -0 "${LOCK_PID}" 2>/dev/null; then
              log_error "Déploiement déjà en cours (PID ${LOCK_PID}). Abandon."
              log_error "  Si c'est une erreur : sudo rm -f ${LOCKFILE}"
              exit 1
            else
              log_warn "Verrou résiduel détecté (PID ${LOCK_PID:-inconnu} mort). Nettoyage."
              sudo rm -f "${LOCKFILE}"
            fi
          fi
          echo $$ | sudo tee "${LOCKFILE}" >/dev/null
          trap 'sudo rm -f "${LOCKFILE}"' EXIT INT TERM
          log_info "Verrou acquis (PID $$)."
        }

        # ---------------------------------------------------------------------------
        # run_with_env DIR CMD...
        # Exécute CMD depuis DIR avec les variables d'environnement chargées.
        # Le premier argument (USER) est conservé par compatibilité mais ignoré.
        #
        # Les exports sont générés par Crystal (env_exports.sh) et copiés
        # dans le wrapper — aucun parsing shell du .env.
        # ---------------------------------------------------------------------------
        run_with_env() {
          _RWE_DIR="$2"
          shift 2
          _RWE_CMD="$*"
          _RWE_WRAPPER=$(mktemp /tmp/.rwe_wrapper.XXXXXX)
          _ENV_EXPORTS="${SHARED_DIR}/env_exports.sh"
          printf '#!/bin/sh\n' > "${_RWE_WRAPPER}"
          printf 'cd %s || exit 1\n' "${_RWE_DIR}" >> "${_RWE_WRAPPER}"
          # Copier les exports pré-générés par Crystal (pas de parsing shell)
          [ -f "${_ENV_EXPORTS}" ] && cat "${_ENV_EXPORTS}" >> "${_RWE_WRAPPER}"
          printf '%s 2>&1\n' "${_RWE_CMD}" >> "${_RWE_WRAPPER}"
          chmod 755 "${_RWE_WRAPPER}"
          /bin/sh "${_RWE_WRAPPER}"
          _RWE_STATUS=$?
          rm -f "${_RWE_WRAPPER}"
          return ${_RWE_STATUS}
        }

        # ==========================================================================
        # INIT
        # ==========================================================================
        init_user() {
          log_section "Utilisateur système"
          if id "${APP_USER}" >/dev/null 2>&1; then
            log_info "Utilisateur ${APP_USER} déjà présent."
          else
            sudo pw useradd -n "${APP_USER}" -d "${APP_HOME}" -m -s /usr/sbin/nologin \
              -c "Deploy ${APP_FULL_NAME}"
            log_info "Utilisateur ${APP_USER} créé."
          fi
        }

        init_directories() {
          log_section "Structure des répertoires"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 755 "${APP_HOME}"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 755 "${RELEASES_DIR}"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 750 "${SHARED_DIR}"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 750 "${SHARED_DIR}/log"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 750 "${SHARED_DIR}/db"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 750 "${SHARED_DIR}/bin"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 755 "${SHARED_DIR}/public"
          log_info "Répertoires créés."
        }

        # ---------------------------------------------------------------------------
        # init_error_page : crée la page d'erreur personnalisée dans shared/public/
        # Cette page remplace les pages d'erreur nginx (502/503/504) pour masquer
        # la signature du serveur web.
        # Le fichier est conservé entre les déploiements (dans shared/, pas current/).
        # ---------------------------------------------------------------------------
        init_error_page() {
          log_section "Page d'erreur personnalisée"
          ERROR_PAGE="${SHARED_DIR}/public/erreur-indisponible.html"
          if [ -f "${ERROR_PAGE}" ]; then
            log_info "Page d'erreur déjà présente : conservée telle quelle."
            return 0
          fi
          sudo tee "${ERROR_PAGE}" >/dev/null << 'ERROR_HTML'
        <!DOCTYPE html>
        <html lang="fr">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Service momentanément indisponible</title>
          <style>
            body {
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
              background: #f5f5f5;
              display: flex;
              align-items: center;
              justify-content: center;
              min-height: 100vh;
              margin: 0;
            }
            .container {
              text-align: center;
              background: white;
              padding: 3rem 4rem;
              border-radius: 8px;
              box-shadow: 0 2px 12px rgba(0,0,0,0.1);
              max-width: 480px;
            }
            h1 { color: #333; font-size: 1.5rem; margin-bottom: 1rem; }
            p  { color: #666; line-height: 1.6; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>Service momentanément indisponible</h1>
            <p>Le service est en cours de maintenance ou de démarrage.<br>
               Merci de réessayer dans quelques instants.</p>
          </div>
        </body>
        </html>
        ERROR_HTML
          sudo chmod 644 "${ERROR_PAGE}"
          sudo chown "${APP_USER}:${APP_GROUP}" "${ERROR_PAGE}"
          log_info "Page d'erreur créée : ${ERROR_PAGE}"
        }

        # ---------------------------------------------------------------------------
        # init_repo : clone le dépôt en mode bare dans shared/repo.git
        # Appelé lors de init (premier déploiement ou ré-initialisation).
        #
        # IMPORTANT — refspec fetch :
        # git clone --bare ne configure PAS de fetch refspec par défaut.
        # Sans refspec, git fetch ne met à jour aucune branche locale du bare.
        # On ajoute explicitement : +refs/heads/*:refs/heads/*
        # Cela permet à clone_repo (git fetch --prune origin) de fonctionner
        # correctement lors de tous les déploiements suivants.
        #
        # Si le bare existe déjà (init relancé), on fait quand même un fetch
        # pour s'assurer qu'il est à jour avant la release.
        # ---------------------------------------------------------------------------
        init_repo() {
          if [ -d "${REPO_DIR}" ]; then
            # Le répertoire existe : vérifier que c'est bien un dépôt git bare.
            # Cas d'un init précédent avorté (clone échoué, clé SSH manquante,
            # etc.) qui aurait laissé un dossier vide ou partiel : on nettoie.
            if git --git-dir="${REPO_DIR}" rev-parse --is-bare-repository >/dev/null 2>&1; then
              log_info "Dépôt bare déjà présent : ${REPO_DIR}"
              # Vérifier que le refspec fetch est bien configuré
              CURRENT_FETCH=$(git --git-dir="${REPO_DIR}" config remote.origin.fetch 2>/dev/null || echo "")
              if [ "${CURRENT_FETCH}" != "+refs/heads/*:refs/heads/*" ]; then
                git --git-dir="${REPO_DIR}" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
                log_info "Refspec fetch corrigé dans le bare."
              fi
              return 0
            else
              log_warn "Répertoire ${REPO_DIR} présent mais ce n'est pas un dépôt git valide (init précédent avorté ?) — suppression et re-clone."
              sudo rm -rf "${REPO_DIR}"
            fi
          fi
          log_section "Initialisation du dépôt bare"
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 750 "${REPO_DIR}"
          if ! git clone --bare "${REPO_URL}" "${REPO_DIR}"; then
            # Échec du clone (clé SSH absente, repo privé, URL fautive…) :
            # on nettoie le dossier vide pour que la prochaine tentative
            # ne soit pas piégée par notre propre garde "déjà présent".
            log_error "Échec du git clone --bare ${REPO_URL}. Nettoyage du dossier vide."
            sudo rm -rf "${REPO_DIR}"
            return 1
          fi
          # Configurer le refspec fetch pour que git fetch --prune origin
          # mette à jour les branches locales du bare (absent par défaut en mode bare)
          git --git-dir="${REPO_DIR}" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
          log_info "Dépôt bare cloné avec refspec fetch configuré : ${REPO_DIR}"
        }

        init_env() {
          log_section "Fichier de configuration .env"
          # Sémantique :
          # - ENV_B64 non vide → l'utilisateur a saisi/confirmé un .env :
          #   on l'écrit (en sauvegardant l'ancien si présent) — c'est le
          #   seul moyen pour les variables auto-injectées (APP_URL,
          #   UNIX_SOCKET, MARTEN_*) d'arriver sur le serveur.
          # - ENV_B64 vide → l'utilisateur a refusé l'envoi : on conserve
          #   le .env existant tel quel.
          if [ -n "${ENV_B64}" ]; then
            if [ -f "${SHARED_DIR}/.env" ]; then
              BACKUP="${SHARED_DIR}/.env.$(date +%Y%m%d-%H%M%S).bak"
              sudo cp "${SHARED_DIR}/.env" "${BACKUP}"
              sudo chmod 600 "${BACKUP}"
              sudo chown "${APP_USER}:${APP_GROUP}" "${BACKUP}"
              log_info "Sauvegarde du .env existant : ${BACKUP}"
            fi
            printf '%s' "${ENV_B64}" | base64 -d | sudo tee "${SHARED_DIR}/.env" >/dev/null
            sudo chmod 640 "${SHARED_DIR}/.env"
            sudo chown "${APP_USER}:${APP_GROUP}" "${SHARED_DIR}/.env"
            log_info "Fichier .env écrit."
          elif [ -f "${SHARED_DIR}/.env" ]; then
            log_info "Fichier .env déjà présent : conservé tel quel."
          else
            log_warn "Aucun .env présent et aucun contenu transmis. Relancez init depuis votre terminal."
          fi
        }

        SHELL_EOF
          init_rcd_function(rcd_b64) +
          <<-'SHELL_EOF'

        # ---------------------------------------------------------------------------
        # create_database : crée l'utilisateur et la base PostgreSQL (sans migrations ni seed)
        # Doit être appelée AVANT run_migrations.
        # ---------------------------------------------------------------------------
        create_database() {
          log_section "Base de données PostgreSQL"
          [ -z "${PG_USER_B64}" ] && { log_info "Pas de configuration PostgreSQL."; return 0; }
          PG_USER=$(printf '%s' "${PG_USER_B64}" | base64 -d)
          PG_PASS=$(printf '%s' "${PG_PASS_B64}" | base64 -d)
          PG_DB=$(printf '%s' "${PG_DB_B64}" | base64 -d)
          PG_HOST=$(printf '%s' "${PG_HOST_B64}" | base64 -d)
          if ! command -v psql >/dev/null 2>&1; then
            log_warn "psql introuvable. Installez PostgreSQL : pkg install postgresql16-client"
            return 0
          fi
          # Créer le rôle si absent
          USER_EXISTS=$(sudo su -m postgres -c \
            "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'\"" 2>/dev/null || echo "")
          if [ "${USER_EXISTS}" != "1" ]; then
            sudo su -m postgres -c \
              "psql -c \"CREATE ROLE ${PG_USER} WITH LOGIN PASSWORD '${PG_PASS}';\"" && \
              log_info "Utilisateur PostgreSQL '${PG_USER}' créé."
          else
            log_info "Utilisateur PostgreSQL '${PG_USER}' déjà présent."
          fi
          # Créer la base si absente
          DB_EXISTS=$(sudo su -m postgres -c \
            "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${PG_DB}'\"" 2>/dev/null || echo "")
          if [ "${DB_EXISTS}" != "1" ]; then
            sudo su -m postgres -c "createdb -O ${PG_USER} ${PG_DB}" && \
              log_info "Base de données '${PG_DB}' créée."
            # Kemal : appliquer le schéma SQL statique si présent
            if [ "${FRAMEWORK}" = "kemal" ] && [ -f "${CURRENT_LINK}/db/schema_pg.sql" ]; then
              sudo su -m postgres -c "psql -d ${PG_DB} -f ${CURRENT_LINK}/db/schema_pg.sql" && \
                log_info "Schéma SQL appliqué."
            fi
          else
            log_info "Base de données '${PG_DB}' déjà présente."
          fi
        }

        # ---------------------------------------------------------------------------
        # run_seed : exécute le seed après activation de la release
        # Marten : `bin/marten seed` si la commande est définie dans le projet
        # Kemal  : `./bin/${APP_FULL_NAME} seed` via le binaire applicatif
        # ---------------------------------------------------------------------------
        run_seed() {
          if [ "${SEED_ENABLED}" = "false" ]; then
            log_info "Seed désactivé via config/deploy.yml (seed: false)."
            return 0
          fi
          [ ! -f "${SHARED_DIR}/.env" ] && return 0
          if [ "${FRAMEWORK}" = "marten" ]; then
            # Seed Marten : commande `seed` via bin/marten si définie dans le projet
            MARTEN_BIN="${CURRENT_LINK}/bin/marten"
            if [ ! -f "${MARTEN_BIN}" ]; then
              log_info "bin/marten introuvable. Seed ignoré."
              return 0
            fi
            if [ -f "${CURRENT_LINK}/seed.cr" ] || grep -rq 'command_name.*seed' \
                "${CURRENT_LINK}/src/" 2>/dev/null; then
              log_section "Seed Marten"
              run_with_env "${APP_USER}" "${CURRENT_LINK}" "./bin/marten seed" || \
                log_warn "Seed retourné une erreur (peut-être déjà initialisé)."
            else
              log_info "Pas de seed Marten détecté."
            fi
          else
            # Kemal : seed via le binaire applicatif
            [ ! -f "${CURRENT_LINK}/bin/${APP_FULL_NAME}" ] && return 0
            log_section "Seed"
            run_with_env "${APP_USER}" "${CURRENT_LINK}" "./bin/${APP_FULL_NAME} seed" || \
              log_warn "Seed retourné une erreur (peut-être déjà initialisé)."
          fi
        }

        # ---------------------------------------------------------------------------
        # init_database : alias de compatibilité (re-init sur un serveur existant)
        # Crée la base si absente, applique les migrations et le seed.
        # ---------------------------------------------------------------------------
        init_database() {
          create_database
          if [ -f "${SHARED_DIR}/.env" ]; then
            if [ "${FRAMEWORK}" = "marten" ]; then
              MARTEN_BIN="${CURRENT_LINK}/bin/marten"
              if [ -f "${MARTEN_BIN}" ]; then
                log_section "Migrations Marten"
                run_with_env "${APP_USER}" "${CURRENT_LINK}" "./bin/marten migrate" || \
                  log_warn "Migrations retournées une erreur (peut-être déjà appliquées)."
              else
                log_warn "bin/marten introuvable dans ${CURRENT_LINK}/bin/. Migrations ignorées."
              fi
            fi
            run_seed
          fi
        }

        # ---------------------------------------------------------------------------
        # init_nginx : lecture des variables selon le framework
        #
        #   kemal  : lit APP_URL et UNIX_SOCKET depuis .env
        #   marten : lit MARTEN_ALLOWED_HOSTS (premier hôte) et MARTEN_SOCKET depuis .env
        # ---------------------------------------------------------------------------
        init_nginx() {
          log_section "Configuration NGINX (framework: ${FRAMEWORK})"
          NGINX_CONF_DEST="${SHARED_DIR}/nginx.conf"

          # Détection du binaire NGINX
          NGINX_BIN=""
          command -v nginx >/dev/null 2>&1 && NGINX_BIN=$(command -v nginx)
          [ -z "${NGINX_BIN}" ] && [ -x "/usr/local/bin/nginx" ] && NGINX_BIN="/usr/local/bin/nginx"
          [ -z "${NGINX_BIN}" ] && \
            NGINX_BIN=$(find /opt -maxdepth 6 -name nginx -type f -perm -u+x 2>/dev/null | head -1)
          [ -n "${NGINX_BIN}" ] && log_info "Binaire NGINX : ${NGINX_BIN}"

          # Mode Passenger ou pkg
          NGINX_MODE="pkg"
          NGINX_CONF_DIR=""
          if [ -d "/opt/websites" ]; then
            NGINX_MODE="passenger"
            NGINX_WEBSITES_DIR="/opt/websites"
            log_info "Mode Passenger : configs dans ${NGINX_WEBSITES_DIR}/"
          fi

          # Détecter NGINX_CONF_DIR
          if [ -n "${NGINX_BIN}" ]; then
            NGINX_PREFIX=$("${NGINX_BIN}" -V 2>&1 | grep -o -- '--prefix=[^ ]*' | cut -d= -f2)
            [ -d "${NGINX_PREFIX}/conf" ]      && NGINX_CONF_DIR="${NGINX_PREFIX}/conf"
            [ -d "${NGINX_PREFIX}/etc/nginx" ] && NGINX_CONF_DIR="${NGINX_PREFIX}/etc/nginx"
          fi
          [ -z "${NGINX_CONF_DIR}" ] && [ -d "/usr/local/etc/nginx" ] && \
            NGINX_CONF_DIR="/usr/local/etc/nginx"
          [ -z "${NGINX_CONF_DIR}" ] && [ -d "/opt/nginx/conf" ] && \
            NGINX_CONF_DIR="/opt/nginx/conf"

          log_info "Mode NGINX : ${NGINX_MODE} | Conf : ${NGINX_CONF_DIR:-inconnu}"

          # Lire SERVER_NAME et SOCKET_PATH selon le framework
          _DEFAULT_SOCKET="/tmp/.${APP_FULL_NAME}.sock"
          SERVER_NAME="${APP_FULL_NAME}.example.app"
          SOCKET_PATH="${_DEFAULT_SOCKET}"

          if [ -f "${SHARED_DIR}/.env" ]; then
            if [ "${FRAMEWORK}" = "marten" ]; then
              # Marten : MARTEN_ALLOWED_HOSTS (premier hôte de la liste CSV) et MARTEN_SOCKET
              ALLOWED_HOSTS_RAW=$(grep '^MARTEN_ALLOWED_HOSTS=' "${SHARED_DIR}/.env" \
                | cut -d= -f2- | tr -d '"')
              FIRST_HOST=$(printf '%s' "${ALLOWED_HOSTS_RAW}" | cut -d, -f1 | tr -d ' ')
              [ -n "${FIRST_HOST}" ] && SERVER_NAME="${FIRST_HOST}"
              SOCKET_ENV=$(grep '^MARTEN_SOCKET=' "${SHARED_DIR}/.env" | cut -d= -f2- | tr -d '"')
              [ -n "${SOCKET_ENV}" ] && SOCKET_PATH="${SOCKET_ENV}"
            else
              # Kemal : APP_URL et UNIX_SOCKET
              APP_URL_RAW=$(grep '^APP_URL=' "${SHARED_DIR}/.env" | cut -d= -f2- | tr -d '"')
              APP_URL_CLEAN=$(printf '%s' "${APP_URL_RAW}" | sed 's|^https://||' | sed 's|^http://||')
              [ -n "${APP_URL_CLEAN}" ] && SERVER_NAME="${APP_URL_CLEAN}"
              SOCKET_ENV=$(grep '^UNIX_SOCKET=' "${SHARED_DIR}/.env" | cut -d= -f2- | tr -d '"')
              case "${SOCKET_ENV}" in
                /var/run/*) : ;; # ancien chemin ignoré
                *) [ -n "${SOCKET_ENV}" ] && SOCKET_PATH="${SOCKET_ENV}" ;;
              esac
            fi
          fi

          # Générer nginx.conf si absent ou si le socket a changé
          _NGINX_NEEDS_REGEN=0
          if [ ! -f "${NGINX_CONF_DEST}" ]; then
            _NGINX_NEEDS_REGEN=1
          elif [ -f "${NGINX_CONF_DEST}" ]; then
            _CURRENT_SOCKET=$(grep 'server unix:' "${NGINX_CONF_DEST}" 2>/dev/null \
              | sed 's/.*server unix://;s/;.*//' | tr -d ' ')
            if [ -n "${_CURRENT_SOCKET}" ] && [ "${_CURRENT_SOCKET}" != "${SOCKET_PATH}" ]; then
              log_warn "Socket changé (${_CURRENT_SOCKET} → ${SOCKET_PATH}). Régénération de nginx.conf."
              _NGINX_NEEDS_REGEN=1
            else
              log_info "nginx.conf déjà présent et cohérent."
            fi
          fi

          if [ "${_NGINX_NEEDS_REGEN}" = "1" ]; then
            # Construire les directives d'assets selon le framework
            if [ "${FRAMEWORK}" = "marten" ]; then
              STATIC_LOCATIONS="    location /assets/ { alias ${APP_HOME}/current/public/assets/; expires 30d; add_header Cache-Control \"public, immutable\"; }"
            else
              STATIC_LOCATIONS="    location /css/    { alias ${APP_HOME}/current/public/css/;    expires 30d; add_header Cache-Control \"public, immutable\"; }
            location /js/     { alias ${APP_HOME}/current/public/js/;     expires 30d; add_header Cache-Control \"public, immutable\"; }
            location /images/ { alias ${APP_HOME}/current/public/images/; expires 30d; add_header Cache-Control \"public, immutable\"; }
            location /vendor/ { alias ${APP_HOME}/current/public/vendor/; expires 30d; add_header Cache-Control \"public, immutable\"; }"
            fi

            sudo tee "${NGINX_CONF_DEST}" >/dev/null << NGINX_CONF
        # Configuration NGINX — ${APP_FULL_NAME}
        # Généré par deploy le $(date) (framework: ${FRAMEWORK})

        upstream ${SERVICE_RC_NAME} {
            server unix:${SOCKET_PATH};
        }

        server {
            listen 80;
            server_name ${SERVER_NAME};

            access_log /var/log/nginx/${APP_FULL_NAME}.access.log;
            error_log  /var/log/nginx/${APP_FULL_NAME}.error.log;

            error_page 502 503 504 /erreur-indisponible.html;
            location = /erreur-indisponible.html {
                root ${APP_HOME}/shared/public;
                internal;
            }

            location / {
                proxy_pass         http://${SERVICE_RC_NAME};
                proxy_set_header   Host              \$host;
                proxy_set_header   X-Real-IP         \$remote_addr;
                proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
                proxy_set_header   X-Forwarded-Proto \$scheme;
                proxy_connect_timeout 60s;
                proxy_send_timeout    60s;
                proxy_read_timeout    60s;
                client_max_body_size  2M;
            }

        ${STATIC_LOCATIONS}
        }

        # Bloc HTTPS — activer après obtention du certificat SSL
        # server {
        #     listen 443 ssl http2;
        #     server_name ${SERVER_NAME};
        #     ssl_certificate     /usr/local/etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem;
        #     ssl_certificate_key /usr/local/etc/letsencrypt/live/${SERVER_NAME}/privkey.pem;
        #     ssl_protocols TLSv1.2 TLSv1.3;
        #     ssl_ciphers HIGH:!aNULL:!MD5;
        #     ...
        # }
        NGINX_CONF
            sudo chmod 644 "${NGINX_CONF_DEST}"
            sudo chown "${APP_USER}:www" "${NGINX_CONF_DEST}"
            log_info "nginx.conf généré : ${NGINX_CONF_DEST}"
          fi

          # Créer le lien selon le mode
          if [ "${NGINX_MODE}" = "passenger" ]; then
            LINK="${NGINX_WEBSITES_DIR}/${APP_FULL_NAME}.conf"
            [ -L "${LINK}" ] || { sudo ln -s "${NGINX_CONF_DEST}" "${LINK}"; log_info "Lien : ${LINK}"; }
            NGINX_MAIN="${NGINX_CONF_DIR}/nginx.conf"
            [ -f "${NGINX_MAIN}" ] && ! grep -q 'opt/websites' "${NGINX_MAIN}" 2>/dev/null && \
              log_warn "Ajoutez dans ${NGINX_MAIN} : include /opt/websites/*.conf;"
          else
            [ -n "${NGINX_CONF_DIR}" ] || { log_warn "NGINX_CONF_DIR inconnu. Copiez ${NGINX_CONF_DEST} manuellement."; return 0; }
            AVAIL="${NGINX_CONF_DIR}/sites-available"
            ENABLED="${NGINX_CONF_DIR}/sites-enabled"
            sudo install -d -o root -g wheel -m 755 "${AVAIL}" "${ENABLED}"
            LINK_A="${AVAIL}/${APP_FULL_NAME}"
            LINK_E="${ENABLED}/${APP_FULL_NAME}"
            [ -L "${LINK_A}" ] || { sudo ln -s "${NGINX_CONF_DEST}" "${LINK_A}"; log_info "Lien : ${LINK_A}"; }
            [ -L "${LINK_E}" ] || { sudo ln -s "${LINK_A}" "${LINK_E}"; log_info "Lien : ${LINK_E}"; }
            NGINX_MAIN="${NGINX_CONF_DIR}/nginx.conf"
            [ -f "${NGINX_MAIN}" ] && ! grep -q 'sites-enabled' "${NGINX_MAIN}" 2>/dev/null && \
              log_warn "Ajoutez dans ${NGINX_MAIN} : include ${NGINX_CONF_DIR}/sites-enabled/*;"
          fi
          log_info "Configuration NGINX terminée. Vérifiez : sudo nginx -t"
        }

        # ==========================================================================
        # DEPLOY
        # ==========================================================================
        clone_repo() {
          log_section "Mise à jour du dépôt et extraction de la release"
          # 1. Mettre à jour le bare avec les derniers commits (seulement les deltas)
          git --git-dir="${REPO_DIR}" fetch --prune origin
          log_info "Dépôt bare mis à jour."
          # 2. Extraire la branche dans le répertoire de release via git archive
          #    (pas de répertoire .git dans la release — propre et minimal)
          sudo install -d -o "${APP_USER}" -g "${APP_GROUP}" -m 755 "${RELEASE_DIR}"
          git --git-dir="${REPO_DIR}" archive "${REPO_BRANCH}" | tar -x -C "${RELEASE_DIR}"
          log_info "Sources extraites dans ${RELEASE_DIR} (branche ${REPO_BRANCH})"
        }

        link_shared() {
          log_section "Liaison des fichiers partagés"
          sudo ln -sf "${SHARED_DIR}/.env" "${RELEASE_DIR}/.env"
          sudo rm -rf "${RELEASE_DIR}/log"
          sudo ln -sf "${SHARED_DIR}/log" "${RELEASE_DIR}/log"
          sudo chown -h "${APP_USER}:${APP_GROUP}" "${RELEASE_DIR}/.env" "${RELEASE_DIR}/log"
          log_info "Fichiers partagés liés."
        }

        # ---------------------------------------------------------------------------
        # shards_prepare : installe les dépendances Crystal (shards install).
        # Étape séquentielle rapide (~15s) à exécuter AVANT compile_start.
        #
        # bin/marten est créé AUTOMATIQUEMENT par le script postinstall de marten
        # (lib/marten/scripts/precompile_marten_cli) lors de shards install.
        # Il ne faut PAS appeler 'shards build marten' : marten ne définit pas
        # de target dans son shard.yml — c'est le postinstall qui compile le CLI.
        #
        # Après shards_prepare, bin/marten est disponible pour run_migrations
        # pendant que crystal build --release tourne en arrière-plan.
        # ---------------------------------------------------------------------------
        shards_prepare() {
          log_section "Installation des dépendances (shards)"
          COMPILE_LOG="/tmp/compile-${APP_FULL_NAME}-${TIMESTAMP}.log"
          cd "${RELEASE_DIR}" || exit 1
          # Si le shard.lock est obsolète (source changée), shards install échoue.
          # On tente d'abord install, et en cas d'échec on fait update pour régénérer le lock.
          sh -c "cd ${RELEASE_DIR} && shards install --production" >> "${COMPILE_LOG}" 2>&1 || \
            sh -c "cd ${RELEASE_DIR} && shards update --production" >> "${COMPILE_LOG}" 2>&1
          if [ "${FRAMEWORK}" = "marten" ]; then
            # Vérifier que bin/marten a bien été créé par le postinstall de marten
            # (lib/marten/scripts/precompile_marten_cli exécuté par shards install)
            if [ -f "${RELEASE_DIR}/bin/marten" ]; then
              log_info "bin/marten disponible (créé par le postinstall de marten)."
            else
              log_warn "bin/marten absent après shards install — migrations et seed ignorés."
            fi
          fi
        }

        # ---------------------------------------------------------------------------
        # compile_start : lance uniquement crystal build --release en arrière-plan.
        # Doit être appelée APRES shards_prepare (bin/marten déjà disponible).
        # Retourne immédiatement pour permettre d'exécuter d'autres tâches en parallèle.
        # Appeler compile_wait ensuite pour attendre la fin et vérifier le résultat.
        # ---------------------------------------------------------------------------
        compile_start() {
          log_section "Compilation Crystal (mode release) — démarrage en arrière-plan"
          COMPILE_SESSION="compile-${APP_FULL_NAME}"
          COMPILE_SCRIPT="/tmp/compile-script-${APP_FULL_NAME}-${TIMESTAMP}.sh"
          cat > "${COMPILE_SCRIPT}" << COMPILE_EOF
        #!/bin/sh
        cd "${RELEASE_DIR}" || exit 1
        # CRYSTAL_FLAGS vaut "-" quand absent (sentinelle pour éviter le décalage d'arguments)
        CRYSTAL_FLAGS_REAL=$([ "${CRYSTAL_FLAGS}" = "-" ] && echo "" || echo "${CRYSTAL_FLAGS}")
        crystal build ${CRYSTAL_FLAGS_REAL} "${CRYSTAL_MAIN}" --release -o "bin/${APP_FULL_NAME}" >> "${COMPILE_LOG}" 2>&1
        [ \$? -eq 0 ] && echo "COMPILE_OK" >> "${COMPILE_LOG}" || echo "COMPILE_FAIL" >> "${COMPILE_LOG}"
        COMPILE_EOF
          chmod 755 "${COMPILE_SCRIPT}"
          if command -v tmux >/dev/null 2>&1; then
            tmux new-session -d -s "${COMPILE_SESSION}" \
              "sh ${COMPILE_SCRIPT}"
            log_info "Compilation lancée en arrière-plan (session tmux : ${COMPILE_SESSION})"
            printf "  En cas de coupure SSH : tmux attach -t %s\n" "${COMPILE_SESSION}"
          else
            # Pas de tmux : lancer en arrière-plan avec & et noter le PID
            sh "${COMPILE_SCRIPT}" &
            COMPILE_BG_PID=$!
            log_info "Compilation lancée en arrière-plan (PID : ${COMPILE_BG_PID})"
          fi
        }

        # ---------------------------------------------------------------------------
        # compile_wait : attend la fin de la compilation (tmux ou PID) et vérifie
        # le résultat. Doit être appelée après compile_start, avant activate_release.
        # ---------------------------------------------------------------------------
        compile_wait() {
          log_section "Attente de la fin de la compilation"
          if command -v tmux >/dev/null 2>&1; then
            ELAPSED=0
            while tmux has-session -t "${COMPILE_SESSION}" 2>/dev/null; do
              sleep 10; ELAPSED=$((ELAPSED + 10))
              printf "  [%ds] Compilation en cours...\r" "${ELAPSED}"
            done
            printf "\n"
          elif [ -n "${COMPILE_BG_PID:-}" ]; then
            ELAPSED=0
            while kill -0 "${COMPILE_BG_PID}" 2>/dev/null; do
              sleep 10; ELAPSED=$((ELAPSED + 10))
              printf "  [%ds] Compilation en cours...\r" "${ELAPSED}"
            done
            printf "\n"
            wait "${COMPILE_BG_PID}" || true
          fi
          if ! grep -q "COMPILE_OK" "${COMPILE_LOG}" 2>/dev/null; then
            log_error "Échec de la compilation. Consultez : ${COMPILE_LOG}"
            exit 1
          fi
          sudo chmod 755 "${RELEASE_DIR}/bin/${APP_FULL_NAME}"
          log_info "Binaire compilé : ${RELEASE_DIR}/bin/${APP_FULL_NAME}"
        }

        # ---------------------------------------------------------------------------
        # compile : version séquentielle (utilisée par deploy).
        # Lance la compilation et attend immédiatement la fin.
        # ---------------------------------------------------------------------------
        compile() {
          compile_start
          compile_wait
        }

        # ---------------------------------------------------------------------------
        # collect_assets : collecte les assets statiques Marten dans public/assets/
        # (bin/marten collectassets --no-input)
        #
        # Marten ne sert les assets en production que via nginx, qui les cherche dans
        # current/public/assets/. Ce dossier n'est PAS versionné dans git (il est
        # généré), donc il faut l'alimenter explicitement après shards install.
        # ---------------------------------------------------------------------------
        collect_assets() {
          [ "${FRAMEWORK}" != "marten" ] && return 0
          MARTEN_BIN="${RELEASE_DIR}/bin/marten"
          if [ ! -f "${MARTEN_BIN}" ]; then
            log_warn "bin/marten introuvable — collecte des assets ignorée."
            return 0
          fi
          log_section "Collecte des assets (bin/marten collectassets)"
          run_with_env "${APP_USER}" "${RELEASE_DIR}" "./bin/marten collectassets --no-input" || {
            log_warn "Échec de la collecte des assets. Les fichiers CSS/JS/images peuvent être absents."
          }
          log_info "Assets collectées dans public/assets/."
        }

        # ---------------------------------------------------------------------------
        # run_migrations : exécuté après compilation, avant activation de la release
        # Marten uniquement — Kemal gère le schéma via init_database
        #
        # IMPORTANT : on utilise `bin/marten migrate` (le binaire Marten lui-même)
        # et non `./bin/${APP_FULL_NAME} migrate`. Le binaire applicatif ne définit
        # pas de commande CLI `migrate` — il démarre le serveur web par défaut.
        # `bin/marten` est installé par `shards install` dans le répertoire du projet.
        # ---------------------------------------------------------------------------
        run_migrations() {
          [ "${FRAMEWORK}" != "marten" ] && return 0
          [ ! -f "${SHARED_DIR}/.env" ] && return 0
          # bin/marten est disponible après `shards install` (script Ruby/Crystal)
          MARTEN_BIN="${RELEASE_DIR}/bin/marten"
          if [ ! -f "${MARTEN_BIN}" ]; then
            log_warn "bin/marten introuvable dans ${RELEASE_DIR}/bin/. Vérifiez que shards install s'est exécuté."
            return 0
          fi
          log_section "Migrations Marten"
          # Traduire les messages anglais de Marten en français via sed.
          # On utilise un fichier temporaire pour préserver le code de retour
          # de bin/marten (un pipe ferait perdre $? au profit du code de sed).
          _MIGRATE_OUT=$(mktemp /tmp/.marten_migrate.XXXXXX)
          # Le || true empêche set -e de tuer le script avant de capturer le code retour
          run_with_env "${APP_USER}" "${RELEASE_DIR}" "./bin/marten migrate" > "${_MIGRATE_OUT}" 2>&1 \
            && _MIGRATE_RC=0 || _MIGRATE_RC=$?
          sed \
            -e 's/No pending migrations to apply/Aucune migration en attente./g' \
            -e 's/Running migrations:/Application des migrations :/g' \
            -e 's/Unapplying /Annulation de /g' \
            -e 's/Applying /Application de /g' \
            -e 's/Planned operations:/Opérations planifiées :/g' \
            "${_MIGRATE_OUT}"
          rm -f "${_MIGRATE_OUT}"
          [ ${_MIGRATE_RC} -eq 0 ] || {
            log_error "Échec des migrations. Déploiement annulé."
            exit 1
          }
          log_info "Migrations appliquées avec succès."
        }

        # ---------------------------------------------------------------------------
        # Arrêt gracieux : envoie SIGTERM au processus Crystal (PID enfant) et
        # attend sa mort avant de basculer la release.
        # ---------------------------------------------------------------------------
        graceful_stop() {
          PIDFILE_PARENT="/tmp/.${APP_FULL_NAME}.pid"
          PIDFILE_CHILD="/tmp/.${APP_FULL_NAME}.child.pid"
          SOCKFILE="${UNIX_SOCKET:-/tmp/.${APP_FULL_NAME}.sock}"

          sudo service "${SERVICE_RC_NAME}" status >/dev/null 2>&1 || {
            log_info "Service déjà arrêté."
            return 0
          }

          DAEMON_PID=""
          [ -f "${PIDFILE_PARENT}" ] && \
            DAEMON_PID=$(cat "${PIDFILE_PARENT}" 2>/dev/null | tr -d '[:space:]')
          if [ -n "${DAEMON_PID}" ] && kill -0 "${DAEMON_PID}" 2>/dev/null; then
            log_info "Arrêt du superviseur daemon(8) PID ${DAEMON_PID}..."
            sudo kill -TERM "${DAEMON_PID}" 2>/dev/null || true
          fi

          CHILD_PID=""
          [ -f "${PIDFILE_CHILD}" ] && \
            CHILD_PID=$(cat "${PIDFILE_CHILD}" 2>/dev/null | tr -d '[:space:]')

          if [ -n "${CHILD_PID}" ] && kill -0 "${CHILD_PID}" 2>/dev/null; then
            PROC_NAME=$(ps -o comm= -p "${CHILD_PID}" 2>/dev/null | tr -d '[:space:]' || true)
            EXPECTED_NAME=$(basename "${APP_FULL_NAME}")
            if [ -n "${PROC_NAME}" ] && [ "${PROC_NAME}" != "${EXPECTED_NAME}" ]; then
              log_warn "PID ${CHILD_PID} appartient à '${PROC_NAME}' (attendu '${EXPECTED_NAME}')."
              log_warn "Le pidfile est probablement périmé. Nettoyage sans SIGTERM."
              CHILD_PID=""
            fi
          fi

          if [ -n "${CHILD_PID}" ] && kill -0 "${CHILD_PID}" 2>/dev/null; then
            log_info "Arrêt gracieux de l'application PID ${CHILD_PID} (SIGTERM)..."
            sudo kill -TERM "${CHILD_PID}" 2>/dev/null || true

            WAIT=0
            while [ "${WAIT}" -lt "${GRACEFUL_TIMEOUT}" ]; do
              sleep 1; WAIT=$((WAIT + 1))
              kill -0 "${CHILD_PID}" 2>/dev/null || {
                log_info "Application terminée après ${WAIT}s."
                break
              }
              [ $((WAIT % 5)) -eq 0 ] && \
                log_info "  En attente de la fin des requêtes en cours (${WAIT}s/${GRACEFUL_TIMEOUT}s)..."
            done

            if kill -0 "${CHILD_PID}" 2>/dev/null; then
              log_warn "Timeout gracieux dépassé (${GRACEFUL_TIMEOUT}s). Envoi de SIGKILL..."
              sudo kill -KILL "${CHILD_PID}" 2>/dev/null || true
              sleep 1
              if kill -0 "${CHILD_PID}" 2>/dev/null; then
                log_error "Impossible de tuer le processus ${CHILD_PID} (processus en état D ?)."
                log_error "Intervention manuelle requise avant de continuer."
                exit 1
              fi
              log_warn "Processus ${CHILD_PID} tué par SIGKILL."
            fi
          else
            log_info "Aucun processus enfant actif trouvé. Arrêt via rc.d..."
            sudo service "${SERVICE_RC_NAME}" stop || true
            sleep 2
          fi

          sudo rm -f "${PIDFILE_CHILD}" && log_info "Pidfile enfant supprimé."
          sudo rm -f "${PIDFILE_PARENT}" && log_info "Pidfile superviseur supprimé."
          { [ -S "${SOCKFILE}" ] || [ -e "${SOCKFILE}" ]; } && \
            { sudo rm -f "${SOCKFILE}"; log_info "Socket supprimé."; } || true
        }

        activate_release() {
          log_section "Activation de la release ${TIMESTAMP}"
          graceful_stop
          sudo ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}"
          sudo chown -h "${APP_USER}:${APP_GROUP}" "${CURRENT_LINK}"
          sudo ln -sf "${CURRENT_LINK}/bin/${APP_FULL_NAME}" "${BIN_LINK}"
          log_info "Lien current → ${RELEASE_DIR}"
        }

        # Génère env_exports.sh à partir du .env.
        # Chaque ligne CLÉ=valeur est convertie en export CLÉ='valeur'.
        # Appelée au deploy AVANT generate_wrapper.
        generate_env_exports() {
          _ENV_FILE="${SHARED_DIR}/.env"
          _ENV_EXPORTS="${SHARED_DIR}/env_exports.sh"
          if [ ! -f "${_ENV_FILE}" ]; then
            log_warn "Pas de .env — env_exports.sh non généré."
            return 0
          fi
          : > "${_ENV_EXPORTS}"
          while IFS= read -r _line || [ -n "${_line}" ]; do
            case "${_line}" in
              ""|\#*) continue ;;
            esac
            _key="${_line%%=*}"
            _val="${_line#*=}"
            case "${_val}" in
              \"*\") _val="${_val%\"}"; _val="${_val#\"}" ;;
              \'*\') _val="${_val%\'}"; _val="${_val#\'}" ;;
            esac
            printf "export %s='%s'\n" "${_key}" "${_val}" >> "${_ENV_EXPORTS}"
          done < "${_ENV_FILE}"
          sudo chmod 640 "${_ENV_EXPORTS}"
          sudo chown "${APP_USER}:${APP_GROUP}" "${_ENV_EXPORTS}"
          log_info "env_exports.sh généré ($(wc -l < "${_ENV_EXPORTS}") variables)."
        }

        # Génère le wrapper de démarrage à partir de env_exports.sh.
        # Appelée au deploy AVANT start_service — ne dépend pas du rc.d precmd.
        generate_wrapper() {
          _WRAPPER="${SHARED_DIR}/bin/${APP_FULL_NAME}"
          _ENV_EXPORTS="${SHARED_DIR}/env_exports.sh"
          sudo mkdir -p "${SHARED_DIR}/bin"
          sudo chown "${APP_USER}:${APP_GROUP}" "${SHARED_DIR}/bin"
          _TMP=$(mktemp /tmp/.wrapper.XXXXXX)
          printf '#!/bin/sh\n' > "${_TMP}"
          printf '# Wrapper — %s (généré automatiquement)\n' "${APP_FULL_NAME}" >> "${_TMP}"
          [ -f "${_ENV_EXPORTS}" ] && cat "${_ENV_EXPORTS}" >> "${_TMP}"
          printf 'cd %s || exit 1\n' "'${CURRENT_LINK}'" >> "${_TMP}"
          printf 'exec %s\n' "'${CURRENT_LINK}/bin/${APP_FULL_NAME}'" >> "${_TMP}"
          sudo cp "${_TMP}" "${_WRAPPER}"
          sudo chmod 750 "${_WRAPPER}"
          sudo chown "${APP_USER}:${APP_GROUP}" "${_WRAPPER}"
          rm -f "${_TMP}"
          log_info "Wrapper généré : ${_WRAPPER}"
        }

        start_service() {
          log_section "Démarrage du service"
          # Nettoyer les pidfiles résiduels si le processus n'existe plus
          # (daemon -r en boucle de crash, arrêt brutal, etc.)
          # graceful_stop a déjà été appelé dans activate_release pour l'arrêt propre.
          _PID_PARENT="/tmp/.${APP_FULL_NAME}.pid"
          if [ -f "${_PID_PARENT}" ]; then
            _STALE_PID=$(cat "${_PID_PARENT}" 2>/dev/null | tr -d '[:space:]')
            if [ -n "${_STALE_PID}" ] && ! kill -0 "${_STALE_PID}" 2>/dev/null; then
              log_warn "Pidfile résiduel détecté (PID ${_STALE_PID} mort). Nettoyage."
              sudo rm -f "${_PID_PARENT}" "/tmp/.${APP_FULL_NAME}.child.pid"
              sudo rm -f "${UNIX_SOCKET:-/tmp/.${APP_FULL_NAME}.sock}"
            elif [ -n "${_STALE_PID}" ] && kill -0 "${_STALE_PID}" 2>/dev/null; then
              # Processus encore vivant (daemon -r en boucle de crash)
              log_warn "Daemon encore actif (PID ${_STALE_PID}). Arrêt forcé."
              sudo kill -TERM "${_STALE_PID}" 2>/dev/null || true
              sleep 2
              kill -0 "${_STALE_PID}" 2>/dev/null && sudo kill -KILL "${_STALE_PID}" 2>/dev/null || true
              sudo rm -f "${_PID_PARENT}" "/tmp/.${APP_FULL_NAME}.child.pid"
              sudo rm -f "${UNIX_SOCKET:-/tmp/.${APP_FULL_NAME}.sock}"
            fi
          fi
          sudo service "${SERVICE_RC_NAME}" start || true
          WAIT=0
          while [ "${WAIT}" -lt 10 ]; do
            sleep 1; WAIT=$((WAIT + 1))
            sudo service "${SERVICE_RC_NAME}" status >/dev/null 2>&1 && {
              log_info "Service ${SERVICE_RC_NAME} démarré avec succès."
              return 0
            }
          done
          log_error "Le service ne répond pas après ${WAIT}s."
          log_error "  sudo tail -f ${SHARED_DIR}/log/${APP_FULL_NAME}.log"
          exit 1
        }

        reload_nginx() {
          log_section "Rechargement de NGINX"
          sudo service nginx status >/dev/null 2>&1 && \
            { sudo nginx -t && sudo service nginx reload; log_info "NGINX rechargé."; } || \
            log_warn "NGINX ne semble pas actif. Ignoré."
        }

        # ==========================================================================
        # CRONTAB — installe config/cron/crontab si présent dans la release
        # ==========================================================================
        install_crontab() {
          CRON_SRC="${CURRENT_LINK}/config/cron/crontab"
          if [ -f "${CRON_SRC}" ]; then
            log_section "Installation du crontab"
            if [ "${FRAMEWORK}" = "marten" ] && [ -f "${CURRENT_LINK}/bin/marten" ]; then
              # Marten : utiliser la commande CLI intégrée
              run_with_env "${APP_USER}" "${CURRENT_LINK}" \
                "export APP_HOME=${APP_HOME} && export APP_FULL_NAME=${APP_FULL_NAME} && ./bin/marten install_cron"
            else
              # Fallback : substitution directe via sed
              CRON_TMP=$(mktemp)
              sed -e "s|{{APP_HOME}}|${APP_HOME}|g" \
                  -e "s|{{APP_FULL_NAME}}|${APP_FULL_NAME}|g" \
                  -e "s|{{MARTEN_ENV}}|${ENV_NAME}|g" \
                  "${CRON_SRC}" > "${CRON_TMP}"
              crontab "${CRON_TMP}"
              rm -f "${CRON_TMP}"
              log_info "Crontab installé pour $(whoami)."
            fi
          fi
        }

        cleanup_releases() {
          log_section "Nettoyage (conservation des ${KEEP_RELEASES} dernières releases)"
          RELEASES_COUNT=$(ls -1 "${RELEASES_DIR}" | wc -l | tr -d ' ')
          if [ "${RELEASES_COUNT}" -gt "${KEEP_RELEASES}" ]; then
            ls -1t "${RELEASES_DIR}" | tail -n "+$((KEEP_RELEASES + 1))" | while read -r dir; do
              log_info "Suppression : ${dir}"
              sudo rm -rf "${RELEASES_DIR:?}/${dir}"
            done
          else
            log_info "Aucune release à supprimer (${RELEASES_COUNT}/${KEEP_RELEASES})."
          fi
        }

        # ==========================================================================
        # ROLLBACK
        # ==========================================================================
        rollback() {
          log_section "Rollback"
          CURRENT_RELEASE=$(readlink "${CURRENT_LINK}" | xargs basename)
          PREV_RELEASE=$(ls -1t "${RELEASES_DIR}" | grep -v "^${CURRENT_RELEASE}$" | head -1)
          [ -z "${PREV_RELEASE}" ] && { log_error "Aucune release précédente disponible."; exit 1; }
          log_warn "Rollback : ${CURRENT_RELEASE} → ${PREV_RELEASE}"
          graceful_stop
          sudo ln -sfn "${RELEASES_DIR}/${PREV_RELEASE}" "${CURRENT_LINK}"
          sudo ln -sf "${CURRENT_LINK}/bin/${APP_FULL_NAME}" "${BIN_LINK}"
          # Rollback des migrations Marten si possible
          if [ "${FRAMEWORK}" = "marten" ] && [ -f "${CURRENT_LINK}/bin/${APP_FULL_NAME}" ] \
              && [ -f "${SHARED_DIR}/.env" ]; then
            log_section "Migrations Marten (rollback vers release précédente)"
            run_with_env "${APP_USER}" "${CURRENT_LINK}" "./bin/${APP_FULL_NAME} migrate" || \
              log_warn "Migrations de rollback retournées une erreur."
          fi
          sudo service "${SERVICE_RC_NAME}" start
          log_info "Rollback effectué vers ${PREV_RELEASE}."
        }

        # ==========================================================================
        # STATUS
        # ==========================================================================
        status() {
          log_section "Statut — ${APP_FULL_NAME}"
          CURRENT_RELEASE=$(readlink "${CURRENT_LINK}" 2>/dev/null | xargs basename 2>/dev/null || echo "aucune")
          printf "Framework       : %s\n" "${FRAMEWORK}"
          printf "Version active  : %s\n" "${CURRENT_RELEASE}"
          printf "Releases disponibles :\n"
          ls -1t "${RELEASES_DIR}" 2>/dev/null | while read -r rel; do
            [ "${rel}" = "${CURRENT_RELEASE}" ] && \
              printf "  * %s  ← current\n" "${rel}" || printf "    %s\n" "${rel}"
          done
          printf "\nService %s : " "${SERVICE_RC_NAME}"
          sudo service "${SERVICE_RC_NAME}" status 2>/dev/null || printf "inactif\n"
          printf "\nVerrou de déploiement : "
          [ -f "${LOCKFILE}" ] && printf "ACTIF (PID %s)\n" "$(cat ${LOCKFILE})" || printf "libre\n"
        }

        # ==========================================================================
        # DISPATCH
        # ==========================================================================
        case "${COMMAND}" in
          init)
            check_sudo
            log_section "Initialisation [${ENV_NAME}] (framework: ${FRAMEWORK})"
            init_user
            init_directories
            init_error_page
            init_env
            init_nginx
            init_repo
            # Dans tous les cas, effectuer une release complète :
            # init_rcd a besoin du script rc.d dans current/config/ qui n'existe
            # qu'après compilation et activation d'une release.
            log_section "Release (fetch + extraction + compilation)"
            DEPLOY_START=$(date +%s)
            clone_repo
            link_shared
            # Étape 1 (séquentielle, rapide ~15s) :
            #   shards install + shards build marten → bin/marten disponible
            shards_prepare
            # Étape 2 (parallèle) :
            #   - crystal build --release en arrière-plan (~200s)
            #   - create_database + run_migrations + run_seed avec bin/marten
            compile_start
            create_database
            run_migrations
            run_seed
            # Point de synchronisation : attendre la fin de crystal build
            # avant d'activer la release (le binaire applicatif doit exister).
            compile_wait
            collect_assets
            activate_release
            # init_rcd doit être appelé APRES activate_release :
            # le script rc.d est dans current/config/ qui vient d'être créé.
            init_rcd
            generate_env_exports
            generate_wrapper
            start_service
            reload_nginx
            DEPLOY_END=$(date +%s)
            DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))
            if [ "${FRAMEWORK}" = "marten" ]; then
              _URL_RAW=$(grep '^MARTEN_ALLOWED_HOSTS=' "${SHARED_DIR}/.env" 2>/dev/null \
                | cut -d= -f2- | tr -d '"' | cut -d, -f1 | tr -d ' ')
            else
              _URL_RAW=$(grep '^APP_URL=' "${SHARED_DIR}/.env" 2>/dev/null \
                | cut -d= -f2- | tr -d '"')
            fi
            # Ajouter https:// si l'URL ne commence pas déjà par http
            case "${_URL_RAW}" in
              http://*|https://*) APP_URL_FINAL="${_URL_RAW}" ;;
              "") APP_URL_FINAL="https://${APP_FULL_NAME}.example.app" ;;
              *) APP_URL_FINAL="https://${_URL_RAW}" ;;
            esac
            log_info "Release compilée et activée."
            log_info "Durée           : $((DEPLOY_DURATION / 60))m $((DEPLOY_DURATION % 60))s"
            log_info "Site disponible : ${APP_URL_FINAL}"
            log_section "Initialisation [${ENV_NAME}] terminée."
            ;;
          deploy)
            check_sudo
            acquire_lock
            [ ! -d "${SHARED_DIR}" ] && { log_error "Lancez d'abord : deploy --${ENV_NAME} init"; exit 1; }
            [ ! -f "${SHARED_DIR}/.env" ] && { log_error ".env absent. Lancez init."; exit 1; }
            grep -q "changez_ce_secret" "${SHARED_DIR}/.env" 2>/dev/null && \
              { log_error ".env contient encore les valeurs par défaut. Éditez-le."; exit 1; }
            DEPLOY_START=$(date +%s)
            log_section "Déploiement [${ENV_NAME}] — ${TIMESTAMP} (framework: ${FRAMEWORK})"
            clone_repo
            link_shared
            # Étape 1 (séquentielle, rapide ~15s) :
            #   shards install + shards build marten → bin/marten disponible
            shards_prepare
            # Étape 2 (parallèle avec crystal build --release ~200s) :
            #   Tout ce qui utilise bin/marten peut tourner pendant la compilation
            compile_start
            run_migrations
            run_seed
            collect_assets
            install_crontab
            # Point de synchronisation : attendre la fin de crystal build
            compile_wait
            activate_release
            init_rcd
            generate_env_exports
            generate_wrapper
            start_service
            reload_nginx
            cleanup_releases
            DEPLOY_END=$(date +%s)
            DEPLOY_DURATION=$((DEPLOY_END - DEPLOY_START))
            # Récupérer l'URL selon le framework
            if [ "${FRAMEWORK}" = "marten" ]; then
              _URL_RAW=$(grep '^MARTEN_ALLOWED_HOSTS=' "${SHARED_DIR}/.env" 2>/dev/null \
                | cut -d= -f2- | tr -d '"' | cut -d, -f1 | tr -d ' ')
            else
              _URL_RAW=$(grep '^APP_URL=' "${SHARED_DIR}/.env" 2>/dev/null \
                | cut -d= -f2- | tr -d '"')
            fi
            # Ajouter https:// si l'URL ne commence pas déjà par http
            case "${_URL_RAW}" in
              http://*|https://*) APP_URL_FINAL="${_URL_RAW}" ;;
              "") APP_URL_FINAL="https://${APP_FULL_NAME}.example.app" ;;
              *) APP_URL_FINAL="https://${_URL_RAW}" ;;
            esac
            log_section "Déploiement [${ENV_NAME}] terminé avec succès !"
            log_info "Version active  : ${TIMESTAMP}"
            log_info "Durée           : $((DEPLOY_DURATION / 60))m $((DEPLOY_DURATION % 60))s"
            log_info "Site disponible : ${APP_URL_FINAL}"
            ;;
          rollback)
            check_sudo
            acquire_lock
            rollback
            ;;
          status)
            status
            ;;
          *)
            printf "Commande inconnue : %s\n" "${COMMAND}"
            exit 1
            ;;
        esac
        exit 0
        SHELL_EOF
      end
    end
  end
end
