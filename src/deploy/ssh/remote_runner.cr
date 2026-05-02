require "base64"

module Deploy
  module SSH
    # Génère le script shell distant, l'envoie sur le serveur et l'exécute.
    # Le script distant contient toute la logique serveur (init, deploy, rollback, status)
    # sous forme de fonctions shell POSIX, exactement comme deploy.sh --remote.
    #
    # Les données sensibles (contenu .env, variables PG) sont transmises via un fichier
    # de données temporaire séparé — jamais en arguments de ligne de commande — pour
    # éviter que le shell du serveur n'interprète les caractères spéciaux (=, /, +, newlines).
    class RemoteRunner
      include Logger

      # Noms uniques basés sur le PID du processus Crystal local
      REMOTE_SCRIPT_NAME = "deploy-remote-#{Process.pid}.sh"
      REMOTE_DATA_NAME   = "deploy-data-#{Process.pid}.env"

      def initialize(
        @client : Client,
        @config : Config,
        @env : Environment,
        @command : String,
        @env_b64 : String = "",
        @pg_user_b64 : String = "",
        @pg_pass_b64 : String = "",
        @pg_db_b64 : String = "",
        @pg_host_b64 : String = "",
      )
      end

      def run : Nil
        remote_script = "/tmp/#{REMOTE_SCRIPT_NAME}"
        remote_data = "/tmp/#{REMOTE_DATA_NAME}"

        # Générer le script distant en mémoire
        script_content = RemoteScript.generate(@config, @env)

        # Fichier de données : chaque valeur sur une ligne séparée (ordre fixe)
        # Le script shell les lira avec `sed -n 'Np'` pour éviter tout problème d'échappement
        data_content = [
          @env_b64,
          @pg_user_b64,
          @pg_pass_b64,
          @pg_db_b64,
          @pg_host_b64,
        ].join("\n") + "\n"

        # Écrire les fichiers temporaires locaux
        tmp_script = File.tempfile("deploy-remote", ".sh")
        tmp_script.print(script_content)
        tmp_script.flush
        tmp_script.close

        tmp_data = File.tempfile("deploy-data", ".env")
        tmp_data.print(data_content)
        tmp_data.flush
        tmp_data.close

        begin
          log_local "Envoi du script sur #{@env.host}..."
          @client.upload(tmp_script.path, remote_script)
          @client.upload(tmp_data.path, remote_data)

          # Générer env_exports.sh depuis Crystal (aucun parsing shell du .env)
          generate_env_exports

          log_local "Lancement de la commande [#{@command}] sur #{@env.host}..."
          cmd = build_remote_command(remote_script, remote_data)
          exit_code = @client.exec_remote(cmd)
          exit exit_code unless exit_code == 0
        ensure
          File.delete(tmp_script.path) rescue nil
          File.delete(tmp_data.path) rescue nil
        end
      end

      # Lit le .env du serveur, le parse en Crystal, et uploade env_exports.sh
      # avec des exports correctement échappés. Plus aucun parsing shell du .env.
      private def generate_env_exports : Nil
        app_home = @env.app_home(@config.app_name)
        env_file = "#{app_home}/shared/.env"
        exports_dest = "#{app_home}/shared/env_exports.sh"

        env_content = @client.read_remote(env_file)
        return unless env_content

        exports = EnvParser.generate_exports(env_content)
        tmp = File.tempfile("env-exports", ".sh")
        begin
          tmp.print(exports)
          tmp.flush
          tmp.close
          @client.upload(tmp.path, exports_dest)
        ensure
          File.delete(tmp.path) rescue nil
        end
      end

      private def build_remote_command(remote_script : String, remote_data : String) : String
        args = [
          "sh #{remote_script}",
          "--remote",
          @env.name,
          @config.app_name,
          @env.branch,
          @config.repo_url,
          @config.crystal_main,
          @config.crystal_flags.try(&.presence) || "-", # "-" si vide pour éviter le décalage d'arguments
          @config.keep_releases.to_s,
          @command,
          remote_data,                     # $10 : chemin du fichier de données
          @config.framework,               # $11 : framework (marten | kemal)
          @config.seed ? "true" : "false", # $12 : seed activé (défaut true)
        ]
        # Nettoyage des fichiers distants après exécution
        args.join(" ") + "; rm -f #{remote_script} #{remote_data}"
      end
    end
  end
end
