require "base64"

module CrystalDeploy
  module DB
    # Dialogue PostgreSQL interactif.
    # Propose deux modes de connexion : socket Unix ou TCP.
    # Aucune valeur par défaut n'est proposée — l'utilisateur saisit tout.
    # Le mot de passe est généré automatiquement si laissé vide.
    #
    # Connexion socket Unix :
    #   Le driver `pg` de Crystal ne supporte pas DB_HOST=/tmp.
    #   On utilise DATABASE_URL avec le paramètre host= pour les deux frameworks.
    #   Marten lit DATABASE_URL s'il est défini (priorité sur DB_HOST/DB_PORT).
    #   Exemple : postgresql://user:pass@/dbname?host=/tmp
    #
    # Connexion TCP :
    #   Marten : DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME
    #   Kemal  : DATABASE_URL
    class Postgresql < Base
      def run_dialog : Hash(String, String)
        log_section I18n.t("db.section")
        puts ""
        puts I18n.t("db.mode_prompt")
        puts I18n.t("db.mode_socket")
        puts I18n.t("db.mode_tcp")
        puts ""

        # Choix par défaut : 1 (socket Unix — recommandé)
        mode = ""
        until %w[1 2].includes?(mode)
          raw = ask(I18n.t("db.choice") + " [1] : ")
          mode = raw.empty? ? "1" : raw
        end

        # Suggestion utilisateur : app_name (tirets → underscores)
        suggested_user = @config.app_name.gsub("-", "_")
        # Suggestion base : app_name__env_name (ex: les_amis_de_joseph__developpement)
        suggested_db = "#{suggested_user}__#{@env.name.gsub("-", "_")}"
        pg_user = ask_with_suggestion(I18n.t("db.user_prompt"), suggested_user)
        pg_pass = ask_password
        pg_db = ask_with_suggestion(I18n.t("db.db_prompt"), suggested_db)
        pg_pool_size = ask_with_suggestion(I18n.t("db.pool_size_prompt"), "10")

        if mode == "1"
          run_socket_dialog(pg_user, pg_pass, pg_db, pg_pool_size)
        else
          run_tcp_dialog(pg_user, pg_pass, pg_db, pg_pool_size)
        end
      end

      # ── Privé ──────────────────────────────────────────────────────────────

      # Socket Unix avec Marten : DB_HOST = répertoire du socket, DB_PORT = 5432.
      # Marten (via crystal-db + pg driver) utilise DB_HOST comme répertoire de socket
      # quand DB_HOST commence par '/' — le driver pg construit alors le chemin
      # /DB_HOST/.s.PGSQL.DB_PORT pour se connecter.
      # DB_PORT ne doit PAS être vide sinon Marten lève KeyError: "DB_PORT".
      private def run_socket_dialog(user : String, pass : String, db : String, pool_size : String) : Hash(String, String)
        socket_dir = ask_with_suggestion(I18n.t("db.socket_dir_prompt"), "/tmp")
        log_info I18n.t("db.socket_info", path: socket_dir)

        if @config.marten?
          {
            "DB_HOST"      => socket_dir,
            "DB_PORT"      => "5432",
            "DB_USER"      => user,
            "DB_PASSWORD"  => pass,
            "DB_NAME"      => db,
            "DB_POOL_SIZE" => pool_size,
          }
        else
          # Kemal : DATABASE_URL avec paramètre host= pour socket Unix
          {
            "DATABASE_URL" => "postgresql://#{user}:#{pass}@/#{db}?host=#{socket_dir}",
          }
        end
      end

      private def run_tcp_dialog(user : String, pass : String, db : String, pool_size : String) : Hash(String, String)
        host = ask_required(I18n.t("db.host_prompt"))

        if @config.marten?
          {
            "DB_HOST"      => host,
            "DB_PORT"      => "5432",
            "DB_USER"      => user,
            "DB_PASSWORD"  => pass,
            "DB_NAME"      => db,
            "DB_POOL_SIZE" => pool_size,
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

      # ── Méthodes de test (accesseurs pour les specs) ──────────────────────
      # Exposent la logique de génération des variables sans passer par le
      # dialogue interactif (stdin). Utilisées uniquement dans les specs.

      def socket_vars_for_test(
        socket_dir : String, user : String, pass : String,
        db : String, pool_size : String,
      ) : Hash(String, String)
        run_socket_dialog_pure(socket_dir, user, pass, db, pool_size)
      end

      def tcp_vars_for_test(
        host : String, user : String, pass : String,
        db : String, pool_size : String,
      ) : Hash(String, String)
        run_tcp_dialog_pure(host, user, pass, db, pool_size)
      end

      # Logique pure de run_socket_dialog sans appel à ask_with_suggestion
      private def run_socket_dialog_pure(
        socket_dir : String, user : String, pass : String,
        db : String, pool_size : String,
      ) : Hash(String, String)
        if @config.marten?
          {
            "DB_HOST"      => socket_dir,
            "DB_PORT"      => "5432",
            "DB_USER"      => user,
            "DB_PASSWORD"  => pass,
            "DB_NAME"      => db,
            "DB_POOL_SIZE" => pool_size,
          }
        else
          {
            "DATABASE_URL" => "postgresql://#{user}:#{pass}@/#{db}?host=#{socket_dir}",
          }
        end
      end

      # Logique pure de run_tcp_dialog sans appel à ask_required
      private def run_tcp_dialog_pure(
        host : String, user : String, pass : String,
        db : String, pool_size : String,
      ) : Hash(String, String)
        if @config.marten?
          {
            "DB_HOST"      => host,
            "DB_PORT"      => "5432",
            "DB_USER"      => user,
            "DB_PASSWORD"  => pass,
            "DB_NAME"      => db,
            "DB_POOL_SIZE" => pool_size,
          }
        else
          {
            "DATABASE_URL" => "postgresql://#{user}:#{pass}@#{host}/#{db}",
          }
        end
      end
    end
  end
end
