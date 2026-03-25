module Aloli
  module Deploy
    module Generators
      # Génère le script rc.d FreeBSD pour un environnement donné.
      # Le script généré est placé dans config/rc.d.<app-full-name>
      # et installé sur le serveur par init_rcd().
      #
      # Double pidfile (amélioration B — arrêt gracieux) :
      #   - pidfile_parent (-P) : PID du superviseur daemon(8) — NE PAS envoyer SIGTERM ici
      #   - pidfile_child  (-p) : PID de l'application Crystal — cible de SIGTERM
      # La distinction est essentielle avec l'option -r (redémarrage automatique) :
      # un SIGTERM sur le daemon superviseur provoque un redémarrage, pas un arrêt.
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

        # Génère le contenu du script rc.d
        def generate : String
          <<-RCD
          #!/bin/sh
          #
          # PROVIDE: #{rc_name}
          # REQUIRE: LOGIN postgresql
          # KEYWORD: shutdown
          #
          # Script rc.d généré par crystal-deploy
          # Application : #{full_name}
          # Environnement : #{@env.name}
          #

          . /etc/rc.subr

          name="#{rc_name}"
          rcvar="#{rc_name}_enable"

          #{rc_name}_user="deploy"
          # pidfile_parent : PID du superviseur daemon(8) (ne pas envoyer SIGTERM ici)
          #{rc_name}_pidfile="/tmp/.#{full_name}.pid"
          # pidfile_child  : PID de l'application Crystal (cible de SIGTERM gracieux)
          #{rc_name}_pidfile_child="/tmp/.#{full_name}.child.pid"
          #{rc_name}_socket="#{socket_path}"
          #{rc_name}_log="#{app_home}/shared/log/#{full_name}.log"

          command="#{app_home}/current/bin/#{full_name}"
          command_args=""

          load_rc_config "${name}"
          : ${#{rc_name}_enable:=NO}

          #{rc_name}_start() {
              echo "Démarrage de ${name}..."

              # Supprimer l'ancien socket si présent (arrêt brutal précédent)
              rm -f "${#{rc_name}_socket}"

              # -P : pidfile du superviseur daemon(8)
              # -p : pidfile de l'application Crystal (enfant direct)
              # -r : redémarrage automatique en cas de crash (supervisé)
              /usr/sbin/daemon \
                  -u "${#{rc_name}_user}" \
                  -P "${#{rc_name}_pidfile}" \
                  -p "${#{rc_name}_pidfile_child}" \
                  -o "${#{rc_name}_log}" \
                  -r \
                  "${command}"

              # Attendre que les deux pidfiles ET le socket soient créés (jusqu'à 15s)
              # daemon(8) -r écrit les pidfiles après un court délai ; le socket est créé
              # par l'application elle-même une fois qu'elle est prête à servir.
              WAIT=0
              while [ "${WAIT}" -lt 15 ]; do
                  sleep 1
                  WAIT=$((WAIT + 1))
                  if [ -f "${#{rc_name}_pidfile}" ] && \
                     [ -f "${#{rc_name}_pidfile_child}" ] && \
                     [ -S "${#{rc_name}_socket}" ]; then
                      break
                  fi
              done

              # Appliquer les permissions sur le socket pour que NGINX (www) puisse y accéder
              if [ -S "${#{rc_name}_socket}" ]; then
                  chown "${#{rc_name}_user}:www" "${#{rc_name}_socket}"
                  chmod 660 "${#{rc_name}_socket}"
              fi

              if [ -f "${#{rc_name}_pidfile_child}" ]; then
                  CHILD_PID=$(cat "${#{rc_name}_pidfile_child}")
                  echo "${name} démarré (PID enfant: ${CHILD_PID})."
              else
                  echo "ERREUR : ${name} n'a pas démarré après ${WAIT}s." >&2
                  echo "Consultez : ${#{rc_name}_log}" >&2
                  return 1
              fi
          }

          #{rc_name}_stop() {
              echo "Arrêt de ${name}..."

              # Arrêter d'abord le superviseur daemon(8) pour désactiver le redémarrage
              # automatique, puis envoyer SIGTERM à l'application Crystal (enfant).
              if [ -f "${#{rc_name}_pidfile}" ]; then
                  DAEMON_PID=$(cat "${#{rc_name}_pidfile}")
                  # SIGTERM au superviseur : il ne relancera plus l'enfant
                  kill "${DAEMON_PID}" 2>/dev/null || true
              fi

              if [ -f "${#{rc_name}_pidfile_child}" ]; then
                  CHILD_PID=$(cat "${#{rc_name}_pidfile_child}")
                  # Vérifier que le PID correspond bien à notre application
                  if kill -0 "${CHILD_PID}" 2>/dev/null; then
                      # SIGTERM → arrêt gracieux (Kemal.stop finit les requêtes en cours)
                      kill -TERM "${CHILD_PID}" 2>/dev/null || true
                      WAIT=0
                      while [ "${WAIT}" -lt 30 ]; do
                          sleep 1
                          WAIT=$((WAIT + 1))
                          kill -0 "${CHILD_PID}" 2>/dev/null || {
                              echo "${name} : processus terminé après ${WAIT}s."
                              break
                          }
                      done
                      # Dernier recours : SIGKILL si toujours vivant après 30s
                      if kill -0 "${CHILD_PID}" 2>/dev/null; then
                          echo "${name} : timeout gracieux dépassé, envoi de SIGKILL." >&2
                          kill -KILL "${CHILD_PID}" 2>/dev/null || true
                          sleep 1
                          # Vérifier que SIGKILL a bien tué le processus
                          if kill -0 "${CHILD_PID}" 2>/dev/null; then
                              echo "ERREUR : impossible de tuer le processus ${CHILD_PID}." >&2
                          fi
                      fi
                  fi
              fi

              # Nettoyage : supprimer le socket EN DERNIER (après mort du processus)
              # pour éviter les 502 Bad Gateway sur les requêtes en cours dans NGINX
              rm -f "${#{rc_name}_pidfile_child}"
              rm -f "${#{rc_name}_pidfile}"
              rm -f "${#{rc_name}_socket}"
              echo "${name} arrêté."
          }

          #{rc_name}_status() {
              # Utiliser le pidfile enfant (PID Crystal) comme référence de statut
              if [ -f "${#{rc_name}_pidfile_child}" ]; then
                  CHILD_PID=$(cat "${#{rc_name}_pidfile_child}")
                  if kill -0 "${CHILD_PID}" 2>/dev/null; then
                      # Vérifier aussi que le socket est présent (application prête)
                      if [ -S "${#{rc_name}_socket}" ]; then
                          echo "${name} est actif et prêt (PID: ${CHILD_PID})."
                      else
                          echo "${name} est actif mais le socket est absent (démarrage en cours ?)."
                      fi
                      return 0
                  else
                      echo "${name} : pidfile enfant présent mais processus mort (PID: ${CHILD_PID})."
                      return 1
                  fi
              elif [ -f "${#{rc_name}_pidfile}" ]; then
                  echo "${name} : superviseur présent mais application non démarrée."
                  return 1
              else
                  echo "${name} est inactif."
                  return 1
              fi
          }

          run_rc_command "$1"
          RCD
        end

        # Écrit le script rc.d dans config/rc.d.<app-full-name>
        def write_to_config_dir : String
          dest = "config/rc.d.#{full_name}"
          Dir.mkdir_p("config") unless Dir.exists?("config")
          File.write(dest, generate)
          File.chmod(dest, 0o755)
          dest
        end
      end
    end
  end
end
