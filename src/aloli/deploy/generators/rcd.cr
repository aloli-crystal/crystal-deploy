module Aloli
  module Deploy
    module Generators
      # Génère le script rc.d FreeBSD pour un environnement donné.
      # Le script généré est placé dans config/rc.d.<app-full-name>
      # et installé sur le serveur par init_rcd().
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
          # Script rc.d généré par aloli-cr-deploy
          # Application : #{full_name}
          # Environnement : #{@env.name}
          #

          . /etc/rc.subr

          name="#{rc_name}"
          rcvar="#{rc_name}_enable"

          #{rc_name}_user="deploy"
          #{rc_name}_pidfile="/var/run/#{@config.app_name}/#{@env.name}.pid"
          #{rc_name}_socket="#{socket_path}"
          #{rc_name}_log="#{app_home}/shared/log/#{full_name}.log"

          command="#{app_home}/current/bin/#{full_name}"
          command_args=""

          load_rc_config "${name}"
          : ${#{rc_name}_enable:=NO}

          #{rc_name}_start() {
              echo "Démarrage de ${name}..."

              # Créer le répertoire du pidfile si absent
              install -d -o deploy -g www -m 750 "/var/run/#{@config.app_name}"

              # Supprimer l'ancien socket si présent (arrêt brutal précédent)
              rm -f "${#{rc_name}_socket}"

              /usr/sbin/daemon \\
                  -u "${#{rc_name}_user}" \\
                  -p "${#{rc_name}_pidfile}" \\
                  -o "${#{rc_name}_log}" \\
                  -r \\
                  "${command}"

              # Attendre que le pidfile ET le socket soient créés (jusqu'à 15s)
              # daemon(8) -r écrit le pidfile après un court délai ; le socket est créé
              # par l'application elle-même une fois qu'elle est prête.
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
                  kill "${PID}" 2>/dev/null || true
                  WAIT=0
                  while [ "${WAIT}" -lt 10 ]; do
                      sleep 1
                      WAIT=$((WAIT + 1))
                      kill -0 "${PID}" 2>/dev/null || break
                  done
                  rm -f "${#{rc_name}_pidfile}"
              fi
              rm -f "${#{rc_name}_socket}"
              echo "${name} arrêté."
          }

          #{rc_name}_status() {
              if [ -f "${#{rc_name}_pidfile}" ]; then
                  PID=$(cat "${#{rc_name}_pidfile}")
                  if kill -0 "${PID}" 2>/dev/null; then
                      echo "${name} est actif (PID: ${PID})."
                      return 0
                  else
                      echo "${name} : pidfile présent mais processus mort."
                      return 1
                  fi
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
