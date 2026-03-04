require "base64"

module Aloli
  module Deploy
    module SSH
      # Génère le script shell distant, l'envoie sur le serveur et l'exécute.
      # Le script distant contient toute la logique serveur (init, deploy, rollback, status)
      # sous forme de fonctions shell POSIX, exactement comme deploy.sh --remote.
      class RemoteRunner
        include Logger

        REMOTE_SCRIPT_TEMPLATE = "deploy-remote-$$.sh"

        def initialize(
          @client : Client,
          @config : Config,
          @env : Environment,
          @command : String,
          @env_b64 : String = "",
          @pg_user_b64 : String = "",
          @pg_pass_b64 : String = "",
          @pg_db_b64 : String = "",
          @pg_host_b64 : String = ""
        )
        end

        def run : Nil
          remote_script = "/tmp/#{REMOTE_SCRIPT_TEMPLATE}"

          # Générer le script distant en mémoire
          script_content = RemoteScript.generate(@config, @env)

          # Écrire dans un fichier temporaire local
          tmp_local = File.tempfile("deploy-remote", ".sh")
          tmp_local.print(script_content)
          tmp_local.flush
          tmp_local.close

          begin
            log_local "Envoi du script sur #{@env.host}..."
            @client.upload(tmp_local.path, remote_script)

            log_local "Lancement de la commande [#{@command}] sur #{@env.host}..."
            cmd = build_remote_command(remote_script)
            exit_code = @client.exec_remote(cmd)
            exit exit_code unless exit_code == 0
          ensure
            File.delete(tmp_local.path) rescue nil
          end
        end

        private def build_remote_command(remote_script : String) : String
          args = [
            "sh #{remote_script}",
            "--remote",
            @env.name,
            @config.app_name,
            @env.branch,
            @config.repo_url,
            @config.crystal_main,
            @config.crystal_flags || "",
            @config.keep_releases.to_s,
            @command,
            "'#{@env_b64}'",
            "'#{@pg_user_b64}'",
            "'#{@pg_pass_b64}'",
            "'#{@pg_db_b64}'",
            "'#{@pg_host_b64}'",
          ]
          args.join(" ") + "; rm -f #{remote_script}"
        end
      end
    end
  end
end
