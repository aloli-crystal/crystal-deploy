module Deploy
  module Generators
    # Génère le script rc.d FreeBSD pour un environnement donné.
    # Le script généré est placé dans shared/rc.d.<app-full-name>
    # et installé sur le serveur par init_rcd().
    #
    # Architecture de démarrage :
    #   daemon(8) -o LOG_FILE → wrapper shell (shared/bin/<full-name>)
    #                              ↳ cd current/
    #                              ↳ exec binaire Crystal
    #
    # daemon(8) gère la redirection vers LOG_FILE (ouvert en tant que root
    # avant le changement d'UID vers deploy). Cela évite les problèmes de
    # permission sur shared/log/ qui appartient à deploy.
    #
    # Le wrapper est (re)généré à chaque démarrage via precmd. C'est un
    # script trivial (cd + exec) qui ne touche plus aux variables d'env.
    #
    # Source des variables d'environnement : `shared/.env`, lu par le
    # binaire lui-même via `aloli-crystal/load-env`. Single source of
    # truth — l'éditeur d'un .env distant n'a qu'à `service ... restart`
    # pour que les nouvelles valeurs prennent. Plus de re-init nécessaire.
    #
    # Le `cd` vers `current/` est ce qui permet à `LoadEnv.load` de
    # trouver `./.env` (qui pointe sur `shared/.env` via symlink).
    #
    # REQUIRE: postgresql
    #   Assure que PostgreSQL est démarré avant ce service.
    #   Indispensable pour les connexions via socket Unix (/tmp/.s.PGSQL.5432).
    #   Sans cette directive, le service peut démarrer avant PostgreSQL au boot
    #   et échouer silencieusement à se connecter à la base de données.
    #   Peut être surchargé via #{rc_name}_require dans /etc/rc.conf si nécessaire
    #   (ex : "mysql" pour MariaDB, ou "" pour désactiver la dépendance).
    class Rcd
      def initialize(@config : Config, @env : Environment)
      end

      def full_name : String
        @env.full_name(@config.app_name)
      end

      def rc_name : String
        @env.service_rc_name(@config.app_name)
      end

      def app_home : String
        @env.app_home(@config.app_name)
      end

      def socket_path : String
        @env.socket_path(@config.app_name)
      end

      def marten_env : String
        @env.name
      end

      # Génère le contenu du script rc.d
      def generate : String
        <<-RCD
        #!/bin/sh
        # =============================================================================
        # rc.d/#{rc_name} — Service FreeBSD pour #{full_name}
        #                     Environnement : #{@env.name}
        #
        # Ce fichier est stocké dans shared/rc.d.#{rc_name}
        # et activé via un lien symbolique géré par deploy :
        #   /usr/local/etc/rc.d/#{rc_name}
        #       → #{app_home}/shared/rc.d.#{rc_name}
        #
        # Activation dans /etc/rc.conf :
        #   #{rc_name}_enable="YES"
        #
        # Pour surcharger la dépendance de démarrage (défaut : postgresql) :
        #   #{rc_name}_require="mysql"   # MariaDB
        #   #{rc_name}_require=""        # aucune dépendance
        #
        # Commandes :
        #   service #{rc_name} start|stop|restart|status
        # =============================================================================
        . /etc/rc.subr

        name="#{rc_name}"
        rcvar="${name}_enable"

        APP_HOME="#{app_home}"
        APP_USER="$(whoami)"
        APP_GROUP="www"
        APP_BIN="${APP_HOME}/current/bin/#{full_name}"

        # Valeurs par défaut (peuvent être surchargées dans /etc/rc.conf)
        : ${#{rc_name}_enable:="NO"}
        : ${#{rc_name}_user:="${APP_USER}"}
        : ${#{rc_name}_group:="${APP_GROUP}"}
        : ${#{rc_name}_dir:="${APP_HOME}/current"}
        # ATTENTION : ne PAS utiliser ${name}_env_file — rc.subr le source
        # automatiquement avec `. $env_file` ce qui casse si les valeurs
        # contiennent des caractères spéciaux (parenthèses, etc.)
        : ${#{rc_name}_dotenv:="${APP_HOME}/shared/.env"}
        : ${#{rc_name}_log:="${APP_HOME}/shared/log/#{full_name}.log"}
        : ${#{rc_name}_pidfile:="/tmp/.#{full_name}.pid"}
        : ${#{rc_name}_socket:="#{socket_path}"}
        : ${#{rc_name}_wrapper:="${APP_HOME}/shared/bin/#{full_name}"}
        # Dépendance de démarrage : assure que PostgreSQL est prêt avant ce service.
        # Indispensable pour les connexions via socket Unix (/tmp/.s.PGSQL.5432).
        : ${#{rc_name}_require:="postgresql"}
        REQUIRE="${#{rc_name}_require}"

        # Hooks
        start_precmd="${name}_precmd"
        start_cmd="${name}_start"
        stop_cmd="${name}_stop"
        status_cmd="${name}_status"

        # Créer les répertoires et fichiers nécessaires avant le démarrage
        #{rc_name}_precmd() {
            install -d \\
                -o "${#{rc_name}_user}" \\
                -g "${#{rc_name}_group}" \\
                -m 750 \\
                "${APP_HOME}/shared/bin"
            # Créer le fichier de log si absent (daemon -o l'ouvre en tant que root)
            if [ ! -f "${#{rc_name}_log}" ]; then
                install -m 640 \\
                    -o "${#{rc_name}_user}" \\
                    -g "${#{rc_name}_group}" \\
                    /dev/null "${#{rc_name}_log}"
            fi
            # Générer le script wrapper (rechargé à chaque démarrage)
            _generate_wrapper
        }

        # Génère shared/bin/#{full_name} : wrapper minimal qui place le
        # cwd sur current/ puis exec le binaire. Le cwd est essentiel
        # pour que `aloli-crystal/load-env` trouve `./.env` (symlink
        # vers shared/.env). Aucun export shell : c'est le binaire qui
        # lit le .env, single source of truth.
        # Le nom du fichier (= APP_FULL_NAME) le fait apparaître
        # clairement dans `ps`.
        _generate_wrapper() {
            WRAPPER="${#{rc_name}_wrapper}"
            APP_DIR="${APP_HOME}/current"
            printf '#!/bin/sh\\n' > "${WRAPPER}"
            printf '# Wrapper de démarrage — #{full_name}\\n' >> "${WRAPPER}"
            printf '# Généré automatiquement par rc.d — ne pas modifier manuellement.\\n' >> "${WRAPPER}"
            printf 'cd %s || exit 1\\n' "'${APP_DIR}'" >> "${WRAPPER}"
            printf 'exec %s\\n' "'${APP_BIN}'" >> "${WRAPPER}"
            chmod 750 "${WRAPPER}"
            chown "${#{rc_name}_user}:${#{rc_name}_group}" "${WRAPPER}"
        }

        #{rc_name}_start() {
            echo "Démarrage de ${name}..."

            # Journaliser le .env au démarrage (mots de passe masqués)
            _log_env

            # Supprimer l'ancien socket si présent (arrêt brutal précédent)
            rm -f "${#{rc_name}_socket}"

            # Lancer le wrapper via daemon(8)
            # -o : daemon ouvre le fichier de log en tant que root avant de changer d'UID
            #      → résout les problèmes de permission sur shared/log/
            # Le wrapper est un script shell nommé comme l'application → visible dans ps
            /usr/sbin/daemon \\
                -u "${#{rc_name}_user}" \\
                -P "${#{rc_name}_pidfile}" \\
                -o "${#{rc_name}_log}" \\
                -r \\
                "${#{rc_name}_wrapper}"

            # Attendre que le pidfile ET le socket soient créés (jusqu'à 15s)
            WAIT=0
            while [ "${WAIT}" -lt 15 ]; do
                sleep 1
                WAIT=$((WAIT + 1))
                if [ -f "${#{rc_name}_pidfile}" ] && \\
                   [ -S "${#{rc_name}_socket}" ]; then
                    break
                fi
            done

            # Appliquer les permissions sur le socket pour que NGINX (www) puisse y accéder
            if [ -S "${#{rc_name}_socket}" ]; then
                chown "${#{rc_name}_user}:www" "${#{rc_name}_socket}"
                chmod 660 "${#{rc_name}_socket}"
            fi

            if [ -f "${#{rc_name}_pidfile}" ]; then
                PID=$(cat "${#{rc_name}_pidfile}")
                # PID écrit, mais le socket peut encore être absent : avertir
                # explicitement et afficher la queue du log pour aider au
                # diagnostic (typiquement : l'app a crashé au bind ou ne lit
                # pas UNIX_SOCKET, retombe en TCP, …).
                if [ ! -S "${#{rc_name}_socket}" ]; then
                    echo "${name} actif (PID: ${PID}) mais le socket ${#{rc_name}_socket} est absent." >&2
                    echo "Dernières lignes du log applicatif (${#{rc_name}_log}) :" >&2
                    tail -n 30 "${#{rc_name}_log}" >&2 || true
                    return 1
                fi
                echo "${name} démarré (PID: ${PID})."
            else
                echo "ERREUR : ${name} n'a pas démarré après ${WAIT}s." >&2
                echo "Dernières lignes du log applicatif (${#{rc_name}_log}) :" >&2
                tail -n 30 "${#{rc_name}_log}" >&2 || true
                return 1
            fi
        }

        #{rc_name}_stop() {
            echo "Arrêt de ${name}..."

            if [ -f "${#{rc_name}_pidfile}" ]; then
                PID=$(cat "${#{rc_name}_pidfile}")
                # Tuer le groupe de processus (daemon superviseur + wrapper + binaire + awk)
                # daemon(8) -r relance après SIGTERM ; SIGTERM sur le superviseur arrête tout
                kill -TERM "${PID}" 2>/dev/null
                # Attendre la terminaison (max 30s)
                WAIT=0
                while [ "${WAIT}" -lt 30 ] && kill -0 "${PID}" 2>/dev/null; do
                    sleep 1
                    WAIT=$((WAIT + 1))
                done
                if kill -0 "${PID}" 2>/dev/null; then
                    echo "${name} : timeout gracieux dépassé, envoi de SIGKILL." >&2
                    kill -KILL "${PID}" 2>/dev/null
                fi
                rm -f "${#{rc_name}_pidfile}"
                rm -f "${#{rc_name}_socket}"
                echo "${name} arrêté."
            else
                echo "${name} n'est pas en cours d'exécution."
            fi
        }

        #{rc_name}_status() {
            if [ -f "${#{rc_name}_pidfile}" ]; then
                PID=$(cat "${#{rc_name}_pidfile}")
                if kill -0 "${PID}" 2>/dev/null; then
                    if [ -S "${#{rc_name}_socket}" ]; then
                        echo "${name} est actif et prêt (PID: ${PID})."
                    else
                        echo "${name} est actif mais le socket est absent (démarrage en cours ?)."
                    fi
                    return 0
                else
                    echo "${name} : fichier PID présent mais processus introuvable."
                    return 1
                fi
            else
                echo "${name} est inactif."
                return 1
            fi
        }

        # Journalise le contenu du .env dans le fichier de log (mots de passe masqués)
        _log_env() {
            ENV_FILE="${#{rc_name}_dotenv}"
            LOG_FILE="${#{rc_name}_log}"
            if [ -f "${ENV_FILE}" ]; then
                echo "--- .env chargé au démarrage ($(date)) ---" >> "${LOG_FILE}"
                # IMPORTANT : `sed -E` (extended regex) pour que l'alternation
                # `|` fonctionne aussi sur BSD sed (FreeBSD, macOS) — le
                # `\\|` de la regex basique est traité comme un littéral
                # par BSD sed et ne masquerait JAMAIS les secrets.
                grep -v '^[[:space:]]*#' "${ENV_FILE}" | grep -v '^[[:space:]]*$' | \\
                    sed -E 's/(PASSWORD|SECRET|TOKEN|API_KEY|APP_PASSWORD|PASS)([^=]*)=.*/\\1\\2=***/' | \\
                    while IFS= read -r line; do
                        echo "  ${line}" >> "${LOG_FILE}"
                    done
                echo "--- fin .env ---" >> "${LOG_FILE}"
            fi
        }

        load_rc_config "${name}"
        run_rc_command "$1"
        RCD
      end

      # Écrit le script rc.d dans config/rc.d.<service-rc-name>
      def write_to_config_dir : String
        dest = "config/rc.d.#{rc_name}"
        Dir.mkdir_p("config") unless Dir.exists?("config")
        File.write(dest, generate)
        File.chmod(dest, 0o755)
        dest
      end
    end
  end
end
