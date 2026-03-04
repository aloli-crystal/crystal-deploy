require "base64"
require "openssl/hmac"

module Aloli
  module Deploy
    module Commands
      class Init
        include Logger

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
        # -----------------------------------------------------------------------
        private def build_env_interactive : {String, String, String, String, String}
          log_section "Configuration de l'environnement (.env)"
          puts ""
          puts "Ce dialogue va construire le fichier .env pour [#{@env.name}]."
          puts "Appuyez sur Entrée pour accepter la valeur par défaut entre crochets."
          puts ""

          env_values = {} of String => String

          # Traiter les variables définies dans deploy.yml
          @config.env_vars.each do |var|
            if var.build_from_pg
              # Géré séparément ci-dessous
              next
            end

            default = resolve_default(var)
            label = default ? "#{var.label} [#{default}]" : var.label
            label += " (optionnel)" if var.optional
            label += " : "

            value = ask(label)
            value = default.to_s if value.empty? && default

            # Génération automatique si vide et generate défini
            if value.empty? && (gen = var.generate)
              value = generate_value(gen)
              log_info "#{var.key} généré automatiquement."
            end

            env_values[var.key] = value
          end

          # PostgreSQL (dialogue dédié si DATABASE_URL doit être construit)
          pg_user, pg_pass, pg_db, pg_host = "", "", "", ""
          if @config.env_vars.any?(&.build_from_pg)
            pg_user, pg_pass, pg_db, pg_host = build_pg_interactive
            env_values["DATABASE_URL"] = "postgresql://#{pg_user}:#{pg_pass}@#{pg_host}/#{pg_db}"
          end

          # Récapitulatif
          puts ""
          log_local "Configuration saisie. Récapitulatif :"
          env_values.each do |k, v|
            next if v.empty?
            display = k.downcase.includes?("secret") || k.downcase.includes?("token") || k.downcase.includes?("key") ? "***" : v
            printf "  %-20s : %s\n", k, display
          end
          puts ""

          return {"", "", "", "", ""} unless confirm?("Confirmer et envoyer sur le serveur ?")

          # Construction du contenu .env
          env_content = build_env_content(env_values)

          env_b64 = Base64.strict_encode(env_content)
          pg_user_b64 = Base64.strict_encode(pg_user)
          pg_pass_b64 = Base64.strict_encode(pg_pass)
          pg_db_b64 = Base64.strict_encode(pg_db)
          pg_host_b64 = Base64.strict_encode(pg_host)

          {env_b64, pg_user_b64, pg_pass_b64, pg_db_b64, pg_host_b64}
        end

        private def build_pg_interactive : {String, String, String, String}
          puts ""
          puts "--- Base de données PostgreSQL ---".colorize.bold
          default_user = @config.app_name.tr("-", "_")
          pg_user = ask("Utilisateur PostgreSQL [#{default_user}] : ")
          pg_user = default_user if pg_user.empty?

          pg_pass = ask("Mot de passe PostgreSQL (vide = générer) : ")
          if pg_pass.empty?
            pg_pass = generate_value("base64_20")
            log_info "Mot de passe généré : #{pg_pass}"
            log_warn "Notez ce mot de passe, il sera écrit dans le .env."
          end

          default_db = "#{@config.app_name.tr("-", "_")}_#{@env.name}"
          pg_db = ask("Nom de la base de données [#{default_db}] : ")
          pg_db = default_db if pg_db.empty?

          pg_host = ask("Hôte PostgreSQL [localhost] : ")
          pg_host = "localhost" if pg_host.empty?

          {pg_user, pg_pass, pg_db, pg_host}
        end

        private def resolve_default(var : EnvVar) : String?
          case var.default_from
          when "app_url"
            @env.app_url
          when "socket_path"
            @env.socket_path(@config.app_name)
          else
            nil
          end
        end

        private def generate_value(type : String) : String
          case type
          when "hex32"
            Random::Secure.hex(32)
          when "base64_20"
            Base64.strict_encode(Random::Secure.random_bytes(15)).tr("+/=", "")[0, 20]
          else
            Random::Secure.hex(16)
          end
        end

        private def build_env_content(values : Hash(String, String)) : String
          lines = ["# Configuration #{@config.app_name} — #{@env.name}",
                   "# Généré par aloli-cr-deploy le #{Time.local}",
                   ""]
          values.each do |k, v|
            lines << "#{k}=#{v}"
          end
          lines.join("\n") + "\n"
        end

        # -----------------------------------------------------------------------
        # Configuration OVH DNS
        # -----------------------------------------------------------------------
        private def setup_ovh : Nil
          return unless (subdomain = @env.dns_subdomain) && (target = @env.dns_target)
          ovh_cfg = @config.ovh
          return unless ovh_cfg

          log_section "Configuration DNS OVH"

          if File.exists?(OVH_RC_PATH)
            log_local "Clés OVH chargées depuis #{OVH_RC_PATH}."
            return unless confirm?("Créer/vérifier le CNAME #{subdomain}.#{ovh_cfg.dns_zone} → #{target} ?")
            ovh_create_cname(ovh_cfg, subdomain, target)
            return
          end

          return unless confirm?("Configurer l'API OVH maintenant ?")

          ovh_help_generate_keys(ovh_cfg.dns_zone)
          return unless confirm?("Avez-vous vos trois clés OVH prêtes ?")

          app_key = ask("OVH Application Key : ")
          app_secret = ask("OVH Application Secret : ")
          consumer_key = ask("OVH Consumer Key : ")

          File.write(OVH_RC_PATH,
            "# Clés API OVH — #{@config.app_name}\n" \
            "# NE PAS VERSIONNER\n\n" \
            "OVH_APP_KEY=#{app_key}\n" \
            "OVH_APP_SECRET=#{app_secret}\n" \
            "OVH_CONSUMER_KEY=#{consumer_key}\n"
          )
          File.chmod(OVH_RC_PATH, 0o600)
          log_local "Clés sauvegardées dans #{OVH_RC_PATH} (permissions 600)."

          ovh_create_cname(ovh_cfg, subdomain, target, app_key, app_secret, consumer_key)
        end

        private def ovh_create_cname(
          ovh : OvhConfig,
          subdomain : String,
          target : String,
          app_key : String = "",
          app_secret : String = "",
          consumer_key : String = ""
        ) : Nil
          # Charger depuis .ovhrc si non fourni
          if app_key.empty? && File.exists?(OVH_RC_PATH)
            File.each_line(OVH_RC_PATH) do |line|
              next if line.starts_with?("#") || line.strip.empty?
              k, _, v = line.partition("=")
              case k.strip
              when "OVH_APP_KEY"      then app_key = v.strip
              when "OVH_APP_SECRET"   then app_secret = v.strip
              when "OVH_CONSUMER_KEY" then consumer_key = v.strip
              end
            end
          end

          log_section "Création CNAME OVH : #{subdomain}.#{ovh.dns_zone} → #{target}"

          unless Process.find_executable("curl")
            log_warn "curl introuvable. Créez le CNAME manuellement."
            return
          end

          api = ovh.api_url
          ts = `curl -s #{api}/auth/time`.strip

          get_url = "#{api}/domain/zone/#{ovh.dns_zone}/record?fieldType=CNAME&subDomain=#{subdomain}"
          get_sig = ovh_sign(app_secret, consumer_key, "GET", get_url, "", ts)

          existing = `curl -s \
            -H "X-Ovh-Application: #{app_key}" \
            -H "X-Ovh-Consumer: #{consumer_key}" \
            -H "X-Ovh-Timestamp: #{ts}" \
            -H "X-Ovh-Signature: $1$#{get_sig}" \
            "#{get_url}"`

          if existing != "[]" && !existing.empty?
            log_info "Enregistrement CNAME déjà présent pour #{subdomain}.#{ovh.dns_zone}."
            return
          end

          post_url = "#{api}/domain/zone/#{ovh.dns_zone}/record"
          body = %Q({"fieldType":"CNAME","subDomain":"#{subdomain}","target":"#{target}","ttl":3600})
          ts = `curl -s #{api}/auth/time`.strip
          post_sig = ovh_sign(app_secret, consumer_key, "POST", post_url, body, ts)

          result = `curl -s -X POST \
            -H "Content-Type: application/json" \
            -H "X-Ovh-Application: #{app_key}" \
            -H "X-Ovh-Consumer: #{consumer_key}" \
            -H "X-Ovh-Timestamp: #{ts}" \
            -H "X-Ovh-Signature: $1$#{post_sig}" \
            -d '#{body}' "#{post_url}"`

          if result.includes?(%("id"))
            log_info "CNAME créé : #{subdomain}.#{ovh.dns_zone} → #{target}"
            ts = `curl -s #{api}/auth/time`.strip
            ref_url = "#{api}/domain/zone/#{ovh.dns_zone}/refresh"
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
        end
      end
    end
  end
end
