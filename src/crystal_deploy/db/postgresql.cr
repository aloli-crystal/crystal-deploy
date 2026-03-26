require "base64"

module CrystalDeploy
  module DB
    # Dialogue PostgreSQL interactif.
    # Propose deux modes de connexion : socket Unix ou TCP.
    # Aucune valeur par défaut n'est proposée — l'utilisateur saisit tout.
    # Le mot de passe est généré automatiquement si laissé vide.
    class Postgresql < Base
      def run_dialog : Hash(String, String)
        log_section I18n.t("db.section")
        puts ""
        puts I18n.t("db.mode_prompt")
        puts I18n.t("db.mode_socket")
        puts I18n.t("db.mode_tcp")
        puts ""

        mode = ""
        until %w[1 2].includes?(mode)
          mode = ask(I18n.t("db.choice") + " : ")
        end

        # Suggestion utilisateur : app_name (tirets → underscores)
        suggested_user = @config.app_name.gsub("-", "_")
        # Suggestion base : app_name__env_name (ex: les_amis_de_joseph__developpement)
        suggested_db = "#{suggested_user}__#{@env.name.gsub("-", "_")}"
        pg_user = ask_with_suggestion(I18n.t("db.user_prompt"), suggested_user)
        pg_pass = ask_password
        pg_db   = ask_with_suggestion(I18n.t("db.db_prompt"), suggested_db)

        if mode == "1"
          run_socket_dialog(pg_user, pg_pass, pg_db)
        else
          run_tcp_dialog(pg_user, pg_pass, pg_db)
        end
      end

      # ── Privé ──────────────────────────────────────────────────────────────

      private def run_socket_dialog(user : String, pass : String, db : String) : Hash(String, String)
        socket_dir = ask_with_suggestion(I18n.t("db.socket_dir_prompt"), "/tmp")
        log_info I18n.t("db.socket_info", path: socket_dir)

        if @config.marten?
          {
            "DB_HOST"     => socket_dir,
            "DB_PORT"     => "",
            "DB_USER"     => user,
            "DB_PASSWORD" => pass,
            "DB_NAME"     => db,
          }
        else
          # Kemal : DATABASE_URL avec paramètre host= pour socket Unix
          {
            "DATABASE_URL" => "postgresql://#{user}:#{pass}@/#{db}?host=#{socket_dir}",
          }
        end
      end

      private def run_tcp_dialog(user : String, pass : String, db : String) : Hash(String, String)
        host = ask_required(I18n.t("db.host_prompt"))

        if @config.marten?
          {
            "DB_HOST"     => host,
            "DB_PORT"     => "5432",
            "DB_USER"     => user,
            "DB_PASSWORD" => pass,
            "DB_NAME"     => db,
          }
        else
          {
            "DATABASE_URL" => "postgresql://#{user}:#{pass}@#{host}/#{db}",
          }
        end
      end

      # Demande un champ obligatoire — redemande jusqu'à obtenir une valeur
      private def ask_required(prompt : String) : String
        loop do
          value = ask("#{prompt} : ")
          return value unless value.empty?
          log_warn I18n.t("init.required_empty")
        end
      end

      # Demande un champ avec une suggestion affichée entre crochets.
      # Si l'utilisateur appuie sur Entrée, la suggestion est utilisée.
      private def ask_with_suggestion(prompt : String, suggestion : String) : String
        loop do
          value = ask("#{prompt} [#{suggestion}] : ")
          return suggestion if value.empty?
          return value
        end
      end

      # Demande le mot de passe — génère automatiquement si vide
      private def ask_password : String
        value = ask(I18n.t("db.password_prompt") + " : ")
        if value.empty?
          generated = generate_password
          log_info I18n.t("db.password_generated")
          log_warn generated
          generated
        else
          value
        end
      end

      private def generate_password : String
        Base64.strict_encode(Random::Secure.random_bytes(15)).tr("+/=", "")[0, 20]
      end
    end
  end
end
