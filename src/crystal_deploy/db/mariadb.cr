require "base64"

module CrystalDeploy
  module DB
    # Dialogue MariaDB/MySQL interactif.
    # Propose deux modes de connexion : socket Unix ou TCP.
    # Aucune valeur par défaut — l'utilisateur saisit tout.
    # Le mot de passe est généré automatiquement si laissé vide.
    class Mariadb < Base
      def run_dialog : Hash(String, String)
        log_section I18n.t("db.section")
        puts ""
        puts I18n.t("db.mode_prompt")
        puts I18n.t("db.mariadb_mode_socket")
        puts I18n.t("db.mode_tcp")
        puts ""

        mode = ""
        until %w[1 2].includes?(mode)
          mode = ask(I18n.t("db.choice") + " : ")
        end

        db_user = ask_required(I18n.t("db.user_prompt"))
        db_pass = ask_password
        db_name = ask_required(I18n.t("db.db_prompt"))

        if mode == "1"
          run_socket_dialog(db_user, db_pass, db_name)
        else
          run_tcp_dialog(db_user, db_pass, db_name)
        end
      end

      # ── Privé ──────────────────────────────────────────────────────────────

      private def run_socket_dialog(user : String, pass : String, db : String) : Hash(String, String)
        socket_path = ask_required(I18n.t("db.mariadb_socket_prompt"))
        log_info I18n.t("db.mariadb_socket_info", path: socket_path)

        if @config.marten?
          {
            "DB_HOST"     => socket_path,
            "DB_PORT"     => "",
            "DB_USER"     => user,
            "DB_PASSWORD" => pass,
            "DB_NAME"     => db,
          }
        else
          {
            "DATABASE_URL" => "mysql://#{user}:#{pass}@/#{db}?socket=#{socket_path}",
          }
        end
      end

      private def run_tcp_dialog(user : String, pass : String, db : String) : Hash(String, String)
        host = ask_required(I18n.t("db.mariadb_host_prompt"))
        port = ask_required(I18n.t("db.mariadb_port_prompt"))

        if @config.marten?
          {
            "DB_HOST"     => host,
            "DB_PORT"     => port,
            "DB_USER"     => user,
            "DB_PASSWORD" => pass,
            "DB_NAME"     => db,
          }
        else
          {
            "DATABASE_URL" => "mysql://#{user}:#{pass}@#{host}:#{port}/#{db}",
          }
        end
      end

      private def ask_required(prompt : String) : String
        loop do
          value = ask("#{prompt} : ")
          return value unless value.empty?
          log_warn I18n.t("init.required_empty")
        end
      end

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
