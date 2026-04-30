require "base64"

module Deploy
  module Commands
    # Commande `init` : initialise le serveur de déploiement.
    #
    # Déroulement :
    #   1. DNS : création/vérification du CNAME (si registrar configuré)
    #   2. Variables obligatoires : SECRET_KEY, etc. (depuis env_vars.yml)
    #   3. Base de données : dialogue dédié (postgresql, sqlite, none)
    #   4. Variables Marten automatiques : MARTEN_ENV, MARTEN_ALLOWED_HOSTS, MARTEN_SOCKET
    #   5. Variables optionnelles : proposées depuis .env.example (si l'utilisateur le souhaite)
    #   6. Récapitulatif + confirmation + envoi SSH
    class Init
      include Logger

      # Les règles des variables sont lues depuis config/deploy.yml (section env_vars:)
      # combinées avec les skip par défaut embarqués dans le binaire.

      def initialize(@config : Config, @env : Environment)
      end

      def run : Nil
        ssh = SSH::Client.new(@env.host, @env.user)
        ssh.check_connection!

        # DNS
        if registrar = @config.dns_registrar
          dns = DNS::Factory.for(registrar, @config, @env)
          dns.try(&.setup)
        end

        existing_remote_env = read_existing_remote_env(ssh)
        unless existing_remote_env.empty?
          log_info "Configuration existante détectée sur #{@env.host} (#{existing_remote_env.size} variables) — Entrée pour conserver chaque valeur."
          puts ""
        end

        # Boucle dialogue → récap → confirmation. Si l'utilisateur refuse
        # l'envoi à l'étape récap, on relance le dialogue pour qu'il puisse
        # corriger les valeurs au lieu de quitter brutalement.
        env_values = pg_vars = nil
        loop do
          env_values, pg_vars = build_env_interactive(existing_remote_env)
          puts ""
          log_section I18n.t("init.summary")
          print_summary(env_values)
          puts ""
          break if confirm?(I18n.t("init.confirm_send"))
          log_warn I18n.t("init.restart_dialog")
          puts ""
        end

        runner = SSH::RemoteRunner.new(
          client: ssh,
          config: @config,
          env: @env,
          command: "init",
          env_b64: Base64.strict_encode(build_env_content(env_values.not_nil!)),
          pg_user_b64: Base64.strict_encode(pg_vars.not_nil!.fetch("DB_USER", "")),
          pg_pass_b64: Base64.strict_encode(pg_vars.not_nil!.fetch("DB_PASSWORD", "")),
          pg_db_b64: Base64.strict_encode(pg_vars.not_nil!.fetch("DB_NAME", "")),
          pg_host_b64: Base64.strict_encode(pg_vars.not_nil!.fetch("DB_HOST", ""))
        )
        runner.run
      end

      # ── Dialogue interactif ─────────────────────────────────────────────────

      private def build_env_interactive(existing : Hash(String, String) = {} of String => String) : {Hash(String, String), Hash(String, String)}
        log_section I18n.t("init.section_env")
        puts ""
        puts I18n.t("init.intro", env: @env.name)
        puts ""

        env_values = {} of String => String

        # Règles effectives : required depuis deploy.yml + skip par défaut du shard
        rules = @config.effective_env_vars

        # ── 1. Variables Marten injectées automatiquement ─────────────────────
        if @config.marten?
          log_section I18n.t("init.auto_injected")
          inject_marten_vars(env_values)
          puts ""
        end

        # ── 2. Variables obligatoires ─────────────────────────────────────────
        log_section I18n.t("init.section_required")
        puts ""

        has_existing_required = rules.required.any? do |v|
          val = existing[v.key]?
          !val.nil? && !val.empty?
        end

        if has_existing_required && !confirm_no?(I18n.t("init.ask_keep_required"))
          # Conserver toutes les variables obligatoires déjà définies, ne demander
          # que celles absentes du serveur.
          rules.required.each do |var_def|
            if (val = existing[var_def.key]?) && !val.empty?
              env_values[var_def.key] = val
            else
              ask_required_var(var_def, env_values, nil)
            end
          end
          log_info I18n.t("init.kept_required")
        else
          rules.required.each do |var_def|
            ask_required_var(var_def, env_values, existing[var_def.key]?)
          end
        end
        puts ""

        # ── 3. Base de données ────────────────────────────────────────────────
        db_adapter = DB::Factory.for(@config.database, @config, @env)
        pg_vars = db_adapter.run_dialog
        env_values.merge!(pg_vars)
        puts ""

        # ── 4. Variables optionnelles depuis .env.example ─────────────────────
        if confirm_no?(I18n.t("init.ask_optional"))
          puts ""
          ask_optional_vars(rules, env_values)
        end

        # Récap + confirmation : déplacés dans run() pour permettre la
        # reprise du dialogue si l'utilisateur refuse l'envoi.

        {env_values, pg_vars}
      end

      # ── Variables Marten automatiques ──────────────────────────────────────

      private def inject_marten_vars(env_values : Hash(String, String)) : Nil
        marten_env = @env.name
        marten_host = @env.hostname
        marten_socket = @env.socket_path(@config.app_name)

        env_values["MARTEN_ENV"] = marten_env
        env_values["MARTEN_ALLOWED_HOSTS"] = marten_host
        env_values["MARTEN_SOCKET"] = marten_socket
        # APP_HOST et APP_PORT : repli TCP si MARTEN_SOCKET n'est pas défini.
        # Valeurs par défaut : 127.0.0.1 et 8000 (défauts Marten).
        env_values["APP_HOST"] = "127.0.0.1"
        env_values["APP_PORT"] = "8000"

        log_info "MARTEN_ENV           = #{marten_env}"
        log_info "MARTEN_ALLOWED_HOSTS = #{marten_host}"
        log_info "MARTEN_SOCKET        = #{marten_socket}"
        log_info "APP_HOST             = 127.0.0.1 (repli TCP)"
        log_info "APP_PORT             = 8000 (repli TCP)"
      end

      # ── Variable obligatoire ───────────────────────────────────────────────

      private def ask_required_var(var_def : EnvVarDef, env_values : Hash(String, String), current_value : String? = nil) : Nil
        has_existing = !current_value.nil? && !current_value.not_nil!.empty?
        hint_parts = [] of String
        hint_parts << "auto-généré si vide" if var_def.generate
        hint_parts << "Entrée = conserver l'actuel" if has_existing
        hint = hint_parts.empty? ? "" : " (#{hint_parts.join(", ")})"
        label = "#{var_def.key}#{hint} : "

        loop do
          value = ask(label)

          if value.empty? && has_existing
            env_values[var_def.key] = current_value.not_nil!
            log_info "  → valeur existante conservée pour #{var_def.key}"
            break
          end

          if value.empty? && var_def.generate
            value = generate_value(var_def.key, var_def.generate.not_nil!)
            log_info I18n.t("init.generated", key: var_def.key)
          end

          if value.empty?
            log_warn I18n.t("init.required_empty")
            next
          end

          env_values[var_def.key] = value
          break
        end
      end

      # Lit le `.env` distant si init a déjà été lancé sur cet environnement.
      # Retourne un hash vide en cas d'absence ou d'erreur de lecture.
      private def read_existing_remote_env(ssh : SSH::Client) : Hash(String, String)
        app_home = @env.app_home(@config.app_name)
        content = ssh.read_remote("#{app_home}/shared/.env")
        content ? parse_env_file(content) : {} of String => String
      rescue
        {} of String => String
      end

      # Parser .env minimaliste : KEY=VALUE, ignore commentaires et lignes
      # vides, retire les guillemets simples ou doubles autour des valeurs.
      private def parse_env_file(content : String) : Hash(String, String)
        result = {} of String => String
        content.each_line do |raw|
          line = raw.strip
          next if line.empty? || line.starts_with?("#")
          line = line.lchop("export ").lstrip if line.starts_with?("export ")
          key, sep, value = line.partition("=")
          next if sep.empty? || key.strip.empty?
          value = value.strip
          if value.size >= 2 && ((value.starts_with?('"') && value.ends_with?('"')) ||
             (value.starts_with?('\'') && value.ends_with?('\'')))
            value = value[1...-1]
          end
          result[key.strip] = value
        end
        result
      end

      # ── Variables optionnelles depuis .env.example ─────────────────────────

      private def ask_optional_vars(rules : EnvVarsConfig, env_values : Hash(String, String)) : Nil
        env_example_path = ".env.example"
        unless File.exists?(env_example_path)
          log_warn ".env.example introuvable — variables optionnelles ignorées."
          return
        end

        optional_vars = @config.load_env_example(
          path: env_example_path,
          skip_keys: rules.skip,
          already_defined: env_values.keys
        )

        if optional_vars.empty?
          log_info "Aucune variable optionnelle supplémentaire dans .env.example."
          return
        end

        log_section I18n.t("init.section_optional")
        puts ""

        optional_vars.each do |var|
          label = var.comment.empty? ? var.key : "#{var.key} — #{var.comment}"
          puts ""
          puts "  #{label}"
          answer = ask("  " + I18n.t("init.ask_var", key: var.key) + " [O/n/valeur] : ")

          case answer.downcase
          when "", "o", "oui", "y", "yes"
            value = ask("  " + I18n.t("init.enter_value") + " : ")
            env_values[var.key] = value unless value.empty?
          when "n", "non", "no"
            next
          else
            # L'utilisateur a saisi directement la valeur
            env_values[var.key] = answer unless answer.empty?
          end
        end
      end

      # ── Récapitulatif ──────────────────────────────────────────────────────

      private def print_summary(env_values : Hash(String, String)) : Nil
        env_values.each do |k, v|
          next if v.empty?
          display = Init.secret_key?(k) ? "***" : v
          printf "  %-30s : %s\n", k, display
        end
      end

      # Détecte les noms de variable qui contiennent un secret (mot de passe,
      # token, clé), pour masquer leur valeur au récapitulatif.
      # Public pour permettre les tests unitaires.
      def self.secret_key?(name : String) : Bool
        lower = name.downcase
        return false if name.starts_with?("STRIPE_PUBLISHABLE")
        lower.includes?("secret") ||
          lower.includes?("password") ||
          lower.includes?("pass") ||
          lower.includes?("token") ||
          lower.includes?("key")
      end

      # ── Génération de valeurs ──────────────────────────────────────────────

      private def generate_value(key : String, method : String) : String
        case method
        when "hex64"
          Random::Secure.hex(32)
        when "hex32"
          Random::Secure.hex(16)
        when "password"
          Base64.strict_encode(Random::Secure.random_bytes(15)).tr("+/=", "")[0, 20]
        else
          Random::Secure.hex(32)
        end
      end

      # ── Construction du fichier .env ───────────────────────────────────────

      private def build_env_content(values : Hash(String, String)) : String
        lines = [
          "# #{@config.app_name} — #{@env.name}",
          "# Généré par deploy le #{Time.local}",
          "",
        ]
        values.each do |k, v|
          next if v.empty?
          lines << "#{k}=#{v}"
        end
        lines.join("\n") + "\n"
      end
    end
  end
end
