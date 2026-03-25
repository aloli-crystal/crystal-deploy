require "base64"
require "openssl/hmac"

module CrystalDeploy
  module Commands
    class Init
      include Logger

      # Chemin du .env local (côté développeur, dans le projet)
      LOCAL_ENV_PATH = ".env"
      # Chemin legacy .ovhrc (conservé pour compatibilité ascendante)
      OVH_RC_PATH = "config/.ovhrc"

      def initialize(@config : Config, @env : Environment)
      end

      def run : Nil
        ssh = SSH::Client.new(@env.host, @env.user)
        ssh.check_connection!

        setup_ovh
        env_b64, pg_user_b64, pg_pass_b64, pg_db_b64, pg_host_b64 = build_env_interactive

        runner = SSH::RemoteRunner.new(
          client: ssh,
          config: @config,
          env: @env,
          command: "init",
          env_b64: env_b64,
          pg_user_b64: pg_user_b64,
          pg_pass_b64: pg_pass_b64,
          pg_db_b64: pg_db_b64,
          pg_host_b64: pg_host_b64
        )
        runner.run
      end

      # -----------------------------------------------------------------------
      # Dialogue interactif pour construire le .env
      #
      # Les variables sont découvertes depuis .env.example du projet.
      # Ordre d'affichage :
      #   1. Variables Marten injectées automatiquement (info seulement)
      #   2. Variables normales AVANT le bloc PostgreSQL
      #   3. Dialogue PostgreSQL dédié (socket Unix ou TCP)
      #   4. Variables normales APRÈS le bloc PostgreSQL
      # -----------------------------------------------------------------------
      private def build_env_interactive : {String, String, String, String, String}
        log_section "Configuration de l'environnement (.env)"
        puts ""
        puts "Ce dialogue va construire le fichier .env pour [#{@env.name}]."
        puts "Appuyez sur Entrée pour accepter la valeur par défaut entre crochets."
        puts ""

        env_values = {} of String => String

        # Charger les variables depuis .env.example
        all_vars = @config.load_env_example

        # ── 1. Variables Marten injectées automatiquement ─────────────────────
        if @config.marten?
          marten_env    = @env.name
          marten_host   = @env.hostname
          marten_socket = @env.socket_path(@config.app_name)
          env_values["MARTEN_ENV"]           = marten_env
          env_values["MARTEN_ALLOWED_HOSTS"] = marten_host
          env_values["MARTEN_SOCKET"]        = marten_socket
          log_info "MARTEN_ENV           = #{marten_env}"
          log_info "MARTEN_ALLOWED_HOSTS = #{marten_host}"
          log_info "MARTEN_SOCKET        = #{marten_socket}"
          puts ""
        end

        # Séparer les variables en trois groupes :
        # - auto : injectées automatiquement (ignorées dans le dialogue)
        # - pg   : construites par le dialogue PostgreSQL
        # - before_pg / after_pg : variables normales avant et après le bloc PG
        has_pg_block = all_vars.any?(&.is_pg)
        pg_block_seen = false

        vars_before_pg = [] of EnvExampleVar
        vars_after_pg  = [] of EnvExampleVar

        all_vars.each do |var|
          next if var.is_marten_auto
          if var.is_pg
            pg_block_seen = true
            next
          end
          if pg_block_seen
            vars_after_pg << var
          else
            vars_before_pg << var
          end
        end

        # ── 2. Variables AVANT PostgreSQL ──────────────────────────────────────
        vars_before_pg.each do |var|
          ask_env_var(var, env_values)
        end

        # ── 3. Dialogue PostgreSQL dédié ───────────────────────────────────────
        pg_user, pg_pass, pg_db, pg_host = "", "", "", ""
        pg_socket_mode = false
        if has_pg_block
          pg_user, pg_pass, pg_db, pg_host, pg_socket_mode = build_pg_interactive
          if @config.marten?
            # Marten : variables DB_* séparées
            env_values["DB_USER"]     = pg_user
            env_values["DB_PASSWORD"] = pg_pass
            env_values["DB_NAME"]     = pg_db
            if pg_socket_mode
              # Socket Unix : DB_HOST = répertoire du socket, DB_PORT vide
              env_values["DB_HOST"] = pg_host
              env_values["DB_PORT"] = ""
            else
              env_values["DB_HOST"] = pg_host
              env_values["DB_PORT"] = "5432"
            end
          else
            # Kemal : DATABASE_URL
            if pg_socket_mode
              env_values["DATABASE_URL"] = "postgresql://#{pg_user}:#{pg_pass}@#{pg_host}/#{pg_db}?host=#{pg_host}"
            else
              env_values["DATABASE_URL"] = "postgresql://#{pg_user}:#{pg_pass}@#{pg_host}/#{pg_db}"
            end
          end
        end

        # ── 4. Variables APRÈS PostgreSQL ──────────────────────────────────────
        vars_after_pg.each do |var|
          ask_env_var(var, env_values)
        end

        # ── Récapitulatif ──────────────────────────────────────────────────────
        puts ""
        log_local "Configuration saisie. Récapitulatif :"
        env_values.each do |k, v|
          next if v.empty?
          is_secret = k.downcase.includes?("secret") ||
                      k.downcase.includes?("token")  ||
                      k.downcase.includes?("key")    ||
                      k.downcase.includes?("password")
          display = is_secret ? "***" : v
          printf "  %-28s : %s\n", k, display
        end
        puts ""

        return {"", "", "", "", ""} unless confirm?("Confirmer et envoyer sur le serveur ?")

        # Construction du contenu .env
        env_content = build_env_content(env_values)

        env_b64     = Base64.strict_encode(env_content)
        pg_user_b64 = Base64.strict_encode(pg_user)
        pg_pass_b64 = Base64.strict_encode(pg_pass)
        pg_db_b64   = Base64.strict_encode(pg_db)
        pg_host_b64 = Base64.strict_encode(pg_host)

        {env_b64, pg_user_b64, pg_pass_b64, pg_db_b64, pg_host_b64}
      end

      # Pose une question pour une variable d'environnement et stocke la réponse
      private def ask_env_var(var : EnvExampleVar, env_values : Hash(String, String)) : Nil
        # Label : utiliser le commentaire du .env.example ou le nom de la clé
        label_text = var.comment.empty? ? var.key : var.comment

        label = if !var.default_value.empty?
          "#{label_text} [#{var.default_value}]"
        elsif var.is_generated
          "#{label_text} [générée automatiquement si vide]"
        else
          label_text
        end
        label += " (optionnel)" if var.comment.downcase.includes?("optionnel") ||
                                   var.comment.downcase.includes?("optional")
        label += " : "

        value = ask(label)
        value = var.default_value if value.empty? && !var.default_value.empty?

        # Génération automatique si vide et clé reconnue comme générée
        if value.empty? && var.is_generated
          value = generate_value(var.key)
          log_info "#{var.key} généré automatiquement."
        end

        env_values[var.key] = value
      end

      private def build_pg_interactive : {String, String, String, String, Bool}
        puts ""
        puts "--- Base de données PostgreSQL ---".colorize.bold
        puts ""
        puts "Mode de connexion :"
        puts "  1) Socket Unix (recommandé si PostgreSQL est sur le même serveur)"
        puts "  2) TCP (host/port, pour un serveur distant)"
        puts ""
        mode = ask("Choix [1] : ")
        mode = "1" if mode.empty?

        default_user = @config.app_name.tr("-", "_")
        pg_user = ask("Utilisateur PostgreSQL [#{default_user}] : ")
        pg_user = default_user if pg_user.empty?

        pg_pass = ask("Mot de passe PostgreSQL [généré automatiquement si vide] : ")
        if pg_pass.empty?
          pg_pass = generate_value("DB_PASSWORD")
          log_info "Mot de passe généré : #{pg_pass}"
          log_warn "Notez ce mot de passe, il sera écrit dans le .env."
        end

        default_db = "#{@config.app_name.tr("-", "_")}_#{@env.name}"
        pg_db = ask("Nom de la base de données [#{default_db}] : ")
        pg_db = default_db if pg_db.empty?

        socket_mode = false
        pg_host = ""
        if mode == "1"
          default_socket = "/var/run/postgresql"
          pg_host = ask("Répertoire du socket PostgreSQL [#{default_socket}] : ")
          pg_host = default_socket if pg_host.empty?
          log_info "Connexion via socket Unix : #{pg_host}/.s.PGSQL.5432"
          socket_mode = true
        else
          pg_host = ask("Hôte PostgreSQL [localhost] : ")
          pg_host = "localhost" if pg_host.empty?
        end

        {pg_user, pg_pass, pg_db, pg_host, socket_mode}
      end

      private def generate_value(key : String) : String
        # Clés à générer en hex64 (clés secrètes longues)
        if key.downcase.includes?("secret_key") || key == "SECRET_KEY"
          return Random::Secure.hex(32)
        end
        # Mots de passe : base64 de 20 caractères
        Base64.strict_encode(Random::Secure.random_bytes(15)).tr("+/=", "")[0, 20]
      end

      private def build_env_content(values : Hash(String, String)) : String
        lines = [
          "# Configuration #{@config.app_name} — #{@env.name}",
          "# Généré par crystal-deploy le #{Time.local}",
          ""
        ]
        values.each do |k, v|
          next if v.empty?
          lines << "#{k}=#{v}"
        end
        lines.join("\n") + "\n"
      end

      # -----------------------------------------------------------------------
      # Lecture des clés OVH
      #
      # Ordre de priorité :
      #   1. Variables d'environnement du shell (OVH_APP_KEY, etc.)
      #   2. Fichier .env local (LOCAL_ENV_PATH)
      #   3. Fichier .ovhrc legacy (OVH_RC_PATH) — compatibilité ascendante
      # -----------------------------------------------------------------------
      private def load_ovh_keys : {String, String, String}
        app_key      = ENV.fetch("OVH_APP_KEY", "")
        app_secret   = ENV.fetch("OVH_APP_SECRET", "")
        consumer_key = ENV.fetch("OVH_CONSUMER_KEY", "")

        # Source 2 : .env local
        if (app_key.empty? || app_secret.empty? || consumer_key.empty?) &&
           File.exists?(LOCAL_ENV_PATH)
          File.each_line(LOCAL_ENV_PATH) do |line|
            next if line.starts_with?("#") || line.strip.empty?
            k, _, v = line.partition("=")
            case k.strip
            when "OVH_APP_KEY"      then app_key      = v.strip if app_key.empty?
            when "OVH_APP_SECRET"   then app_secret   = v.strip if app_secret.empty?
            when "OVH_CONSUMER_KEY" then consumer_key = v.strip if consumer_key.empty?
            end
          end
        end

        # Source 3 : .ovhrc legacy
        if (app_key.empty? || app_secret.empty? || consumer_key.empty?) &&
           File.exists?(OVH_RC_PATH)
          log_warn "Clés OVH chargées depuis #{OVH_RC_PATH} (legacy)."
          log_warn "Migrez-les vers votre .env local (OVH_APP_KEY, OVH_APP_SECRET, OVH_CONSUMER_KEY)."
          File.each_line(OVH_RC_PATH) do |line|
            next if line.starts_with?("#") || line.strip.empty?
            k, _, v = line.partition("=")
            case k.strip
            when "OVH_APP_KEY"      then app_key      = v.strip if app_key.empty?
            when "OVH_APP_SECRET"   then app_secret   = v.strip if app_secret.empty?
            when "OVH_CONSUMER_KEY" then consumer_key = v.strip if consumer_key.empty?
            end
          end
        end

        {app_key, app_secret, consumer_key}
      end

      # Écrit ou met à jour les clés OVH dans le .env local
      private def save_ovh_keys_to_env(app_key : String,
                                        app_secret : String,
                                        consumer_key : String) : Nil
        env_path = LOCAL_ENV_PATH
        existing_lines = File.exists?(env_path) ? File.read_lines(env_path) : [] of String

        ovh_keys = %w[OVH_APP_KEY OVH_APP_SECRET OVH_CONSUMER_KEY]
        filtered = existing_lines.reject { |l| ovh_keys.any? { |k| l.starts_with?("#{k}=") } }

        unless filtered.empty? || filtered.last.strip.empty?
          filtered << ""
        end

        filtered << "# Clés API OVH — NE PAS VERSIONNER"
        filtered << "OVH_APP_KEY=#{app_key}"
        filtered << "OVH_APP_SECRET=#{app_secret}"
        filtered << "OVH_CONSUMER_KEY=#{consumer_key}"
        filtered << ""

        File.write(env_path, filtered.join("\n"))
        File.chmod(env_path, 0o600)
        log_local "Clés OVH sauvegardées dans #{env_path} (permissions 600)."
        log_warn "Vérifiez que #{env_path} est bien dans votre .gitignore !"
      end

      # -----------------------------------------------------------------------
      # Configuration OVH DNS
      # La zone DNS et la cible sont déduites du app_url de l'environnement
      # -----------------------------------------------------------------------
      private def setup_ovh : Nil
        subdomain = @env.dns_subdomain
        target    = @env.resolved_dns_target
        dns_zone  = @env.dns_zone

        return if subdomain.empty? || target.empty?

        log_section "Configuration DNS OVH"

        app_key, app_secret, consumer_key = load_ovh_keys

        if !app_key.empty? && !app_secret.empty? && !consumer_key.empty?
          log_local "Clés OVH trouvées."
          return unless confirm?("Créer/vérifier le CNAME #{subdomain}.#{dns_zone} → #{target} ?")
          ovh_create_cname(dns_zone, subdomain, target, app_key, app_secret, consumer_key)
          return
        end

        return unless confirm?("Configurer l'API OVH maintenant ?")

        ovh_help_generate_keys(dns_zone)
        return unless confirm?("Avez-vous vos trois clés OVH prêtes ?")

        app_key      = ask("OVH Application Key : ")
        app_secret   = ask("OVH Application Secret : ")
        consumer_key = ask("OVH Consumer Key : ")

        save_ovh_keys_to_env(app_key, app_secret, consumer_key)
        ovh_create_cname(dns_zone, subdomain, target, app_key, app_secret, consumer_key)
      end

      private def ovh_create_cname(
        dns_zone : String,
        subdomain : String,
        target : String,
        app_key : String,
        app_secret : String,
        consumer_key : String
      ) : Nil
        log_section "Création CNAME OVH : #{subdomain}.#{dns_zone} → #{target}"

        unless Process.find_executable("curl")
          log_warn "curl introuvable. Créez le CNAME manuellement."
          return
        end

        api = @config.ovh_api_url
        ts = `curl -s #{api}/auth/time`.strip

        get_url = "#{api}/domain/zone/#{dns_zone}/record?fieldType=CNAME&subDomain=#{subdomain}"
        get_sig = ovh_sign(app_secret, consumer_key, "GET", get_url, "", ts)

        existing = `curl -s \
          -H "X-Ovh-Application: #{app_key}" \
          -H "X-Ovh-Consumer: #{consumer_key}" \
          -H "X-Ovh-Timestamp: #{ts}" \
          -H "X-Ovh-Signature: $1$#{get_sig}" \
          "#{get_url}"`

        if existing != "[]" && !existing.empty?
          log_info "Enregistrement CNAME déjà présent pour #{subdomain}.#{dns_zone}."
          return
        end

        post_url = "#{api}/domain/zone/#{dns_zone}/record"
        body     = %Q({"fieldType":"CNAME","subDomain":"#{subdomain}","target":"#{target}","ttl":3600})
        ts       = `curl -s #{api}/auth/time`.strip
        post_sig = ovh_sign(app_secret, consumer_key, "POST", post_url, body, ts)

        result = `curl -s -X POST \
          -H "Content-Type: application/json" \
          -H "X-Ovh-Application: #{app_key}" \
          -H "X-Ovh-Consumer: #{consumer_key}" \
          -H "X-Ovh-Timestamp: #{ts}" \
          -H "X-Ovh-Signature: $1$#{post_sig}" \
          -d '#{body}' "#{post_url}"`

        if result.includes?(%("id"))
          log_info "CNAME créé : #{subdomain}.#{dns_zone} → #{target}"
          ts      = `curl -s #{api}/auth/time`.strip
          ref_url = "#{api}/domain/zone/#{dns_zone}/refresh"
          ref_sig = ovh_sign(app_secret, consumer_key, "POST", ref_url, "", ts)
          `curl -s -X POST \
            -H "X-Ovh-Application: #{app_key}" \
            -H "X-Ovh-Consumer: #{consumer_key}" \
            -H "X-Ovh-Timestamp: #{ts}" \
            -H "X-Ovh-Signature: $1$#{ref_sig}" \
            "#{ref_url}"`
          log_info "Zone DNS rafraîchie."
        else
          log_warn "Réponse inattendue de l'API OVH : #{result}"
        end
      end

      private def ovh_sign(secret : String, consumer : String, method : String,
                           url : String, body : String, ts : String) : String
        data = "#{secret}+#{consumer}+#{method}+#{url}+#{body}+#{ts}"
        OpenSSL::HMAC.hexdigest(:sha1, secret, data)
      end

      private def ovh_help_generate_keys(dns_zone : String) : Nil
        puts ""
        puts "╔══════════════════════════════════════════════════════╗".colorize(:cyan).bold
        puts "║       Génération des clés API OVH — Guide rapide     ║".colorize(:cyan).bold
        puts "╚══════════════════════════════════════════════════════╝".colorize(:cyan).bold
        puts ""
        puts "Étape 1 — Créez l'application sur : https://eu.api.ovh.com/createApp/"
        puts "Étape 2 — Générez le Consumer Key avec curl (voir README.adoc)"
        puts "Étape 3 — Renseignez les trois clés ci-dessous."
        puts ""
        puts "Les clés seront sauvegardées dans votre .env local."
        puts "Vérifiez que .env est dans votre .gitignore !"
        puts ""
      end
    end
  end
end