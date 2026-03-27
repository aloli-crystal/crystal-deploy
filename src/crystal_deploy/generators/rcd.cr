module CrystalDeploy
  module Generators
    # Génère le script rc.d FreeBSD pour un environnement donné.
    # Le script généré est placé dans shared/rc.d.<app-full-name>
    # et installé sur le serveur par init_rcd().
    #
    # Architecture de démarrage :
    #   daemon(8) -o LOG_FILE → wrapper shell (shared/bin/<full-name>)
    #                              ↳ charge shared/.env (set -a / set +a)
    #                              ↳ exec binaire Crystal
    #
    # daemon(8) gère la redirection vers LOG_FILE (ouvert en tant que root
    # avant le changement d'UID vers deploy). Cela évite les problèmes de
    # permission sur shared/log/ qui appartient à deploy.
    #
    # Le wrapper est (re)généré à chaque démarrage via precmd.
    # Cela garantit que les variables d'environnement sont toujours à jour.
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
        # et activé via un lien symbolique géré par crystal-deploy :
        #   /usr/local/etc/rc.d/#{rc_name}
        #       → #{app_home}/shared/rc.d.#{rc_name}
        #
        # Activation dans /etc/rc.conf :
        #   #{rc_name}_enable="YES"
        #
        # Commandes :
        #   service #{rc_name} start|stop|restart|status
        # =============================================================================
        . /etc/rc.subr

        name="#{rc_name}"
        rcvar="${name}_enable"

        APP_HOME="#{app_home}"
        APP_USER="deploy"
        APP_GROUP="www"
        APP_BIN="${APP_HOME}/current/bin/#{full_name}"

        # Valeurs par défaut (peuvent être surchargées dans /etc/rc.conf)
        : ${#{rc_name}_enable:="NO"}
        : ${#{rc_name}_user:="${APP_USER}"}
        : ${#{rc_name}_group:="${APP_GROUP}"}
        : ${#{rc_name}_dir:="${APP_HOME}/current"}
        : ${#{rc_name}_env_file:="${APP_HOME}/shared/.env"}
        : ${#{rc_name}_log:="${APP_HOME}/shared/log/#{full_name}.log"}
        : ${#{rc_name}_pidfile:="/tmp/.#{full_name}.pid"}
        : ${#{rc_name}_socket:="#{socket_path}"}
        : ${#{rc_name}_wrapper:="${APP_HOME}/shared/bin/#{full_name}"}

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

        # Génère shared/bin/#{full_name} :
        # script shell nommé comme l'application pour apparaître clairement dans ps.
        # Il charge le .env, exporte les variables nécessaires, lance le binaire
        # et horodate chaque ligne de log via awk.
        _generate_wrapper() {
            ENV_FILE="${#{rc_name}_env_file}"
            LOG_FILE="${#{rc_name}_log}"
            APP_SOCKET="${#{rc_name}_socket}"
            WRAPPER="${#{rc_name}_wrapper}"
            cat > "${WRAPPER}" << WRAPPER_EOF
        #!/bin/sh
        # Wrapper de démarrage — #{full_name}
        # Généré automatiquement par rc.d — ne pas modifier manuellement.
        set -a
        . '${ENV_FILE}'
        set +a
        exec '${APP_BIN}'
        WRAPPER_EOF
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
                echo "${name} démarré (PID: ${PID})."
            else
                echo "ERREUR : ${name} n'a pas démarré après ${WAIT}s." >&2
                echo "Consultez : ${#{rc_name}_log}" >&2
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
            ENV_FILE="${#{rc_name}_env_file}"
            LOG_FILE="${#{rc_name}_log}"
            if [ -f "${ENV_FILE}" ]; then
                echo "--- .env chargé au démarrage ($(date)) ---" >> "${LOG_FILE}"
                grep -v '^[[:space:]]*#' "${ENV_FILE}" | grep -v '^[[:space:]]*$' | \\
                    sed 's/\\(PASSWORD\\|SECRET\\|TOKEN\\|KEY\\|PASS\\)\\([^=]*\\)=.*/\\1\\2=***/' | \\
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
