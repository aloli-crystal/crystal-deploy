module CrystalDeploy
  module DNS
    # Implémentation OVH de l'interface DNS.
    # Utilise l'API REST OVH v1 pour créer des enregistrements CNAME.
    #
    # Credentials lus dans cet ordre de priorité :
    #   1. Variables d'environnement : OVH_APP_KEY, OVH_APP_SECRET, OVH_CONSUMER_KEY
    #   2. Fichier .env local (LOCAL_ENV_PATH)
    #
    # Signature OVH : SHA1 simple (PAS HMAC) sur la chaîne
    #   APP_SECRET+CONSUMER_KEY+METHOD+URL+BODY+TIMESTAMP
    # Calculée via `openssl dgst -sha1 -hex` (identique à table-de-gaya/config/deploy.sh).
    class Ovh < Base
      LOCAL_ENV_PATH = ".env"
      API_URL        = "https://eu.api.ovh.com/1.0"

      def registrar_name : String
        "OVH"
      end

      def credentials_present? : Bool
        !@app_key.empty? && !@app_secret.empty? && !@consumer_key.empty?
      end

      def load_credentials : Nil
        # Source 1 : variables d'environnement
        @app_key      = ENV.fetch("OVH_APP_KEY", "")
        @app_secret   = ENV.fetch("OVH_APP_SECRET", "")
        @consumer_key = ENV.fetch("OVH_CONSUMER_KEY", "")

        return if credentials_present?

        # Source 2 : .env local
        if File.exists?(LOCAL_ENV_PATH)
          File.each_line(LOCAL_ENV_PATH) do |line|
            next if line.strip.starts_with?("#") || line.strip.empty?
            k, _, v = line.partition("=")
            case k.strip
            when "OVH_APP_KEY"      then @app_key      = v.strip if @app_key.empty?
            when "OVH_APP_SECRET"   then @app_secret   = v.strip if @app_secret.empty?
            when "OVH_CONSUMER_KEY" then @consumer_key = v.strip if @consumer_key.empty?
            end
          end
        end
      end

      def ask_credentials : Nil
        @app_key      = ask(I18n.t("dns.key_app_key") + " : ")
        @app_secret   = ask(I18n.t("dns.key_app_secret") + " : ")
        @consumer_key = ask(I18n.t("dns.key_consumer_key") + " : ")
      end

      def save_credentials : Nil
        env_path = LOCAL_ENV_PATH
        existing = File.exists?(env_path) ? File.read_lines(env_path) : [] of String

        ovh_keys = %w[OVH_APP_KEY OVH_APP_SECRET OVH_CONSUMER_KEY]
        filtered = existing.reject { |l| ovh_keys.any? { |k| l.starts_with?("#{k}=") } }

        filtered << "" unless filtered.empty? || filtered.last.strip.empty?
        filtered << "# Clés API OVH — NE PAS VERSIONNER"
        filtered << "OVH_APP_KEY=#{@app_key}"
        filtered << "OVH_APP_SECRET=#{@app_secret}"
        filtered << "OVH_CONSUMER_KEY=#{@consumer_key}"
        filtered << ""

        File.write(env_path, filtered.join("\n"))
        File.chmod(env_path, 0o600)
        log_local I18n.t("dns.saved", path: env_path)
        log_warn I18n.t("dns.check_gitignore", path: env_path)
      end

      def help_generate_keys(zone : String) : Nil
        puts ""
        puts "╔══════════════════════════════════════════════════════╗".colorize(:cyan).bold
        puts "║         Génération des clés API OVH                  ║".colorize(:cyan).bold
        puts "╚══════════════════════════════════════════════════════╝".colorize(:cyan).bold
        puts ""
        puts I18n.t("dns.ovh_step1")
        puts I18n.t("dns.ovh_step2")
        puts I18n.t("dns.ovh_step3")
        puts ""
        puts I18n.t("dns.keys_saved_in")
        puts ""
      end

      def create_cname(subdomain : String, target : String, zone : String) : Nil
        log_section "CNAME : #{subdomain}.#{zone} → #{target}"

        unless Process.find_executable("curl")
          log_warn "curl introuvable. Créez le CNAME manuellement dans votre espace OVH."
          return
        end

        unless Process.find_executable("openssl")
          log_warn "openssl introuvable. Créez le CNAME manuellement dans votre espace OVH."
          return
        end

        ts = `curl -s #{API_URL}/auth/time`.strip

        # Vérifier si le CNAME existe déjà
        # L'API OVH retourne un tableau JSON d'IDs numériques quand des enregistrements
        # existent, ex: [12345678] ou [12345678, 87654321].
        # Si aucun enregistrement : []
        # En cas d'erreur d'authentification : {"class":"...","message":"..."} (sans "error")
        # → On vérifie strictement que la réponse est un tableau JSON non vide de nombres.
        get_url = "#{API_URL}/domain/zone/#{zone}/record?fieldType=CNAME&subDomain=#{subdomain}"
        get_sig = sign(@app_secret, @consumer_key, "GET", get_url, "", ts)

        existing = `curl -s \
          -H "X-Ovh-Application: #{@app_key}" \
          -H "X-Ovh-Consumer: #{@consumer_key}" \
          -H "X-Ovh-Timestamp: #{ts}" \
          -H "X-Ovh-Signature: $1$#{get_sig}" \
          "#{get_url}"`.strip

        # Un tableau non vide d'IDs numériques commence par "[" suivi d'un chiffre
        cname_exists = !!(existing =~ /^\[\s*\d/)

        if cname_exists
          log_info I18n.t("dns.cname_exists", sub: subdomain, zone: zone)
          return
        end

        # Réponse inattendue (ni "[]" ni tableau d'IDs) → probablement une erreur API
        if existing != "[]" && !existing.empty?
          log_warn I18n.t("dns.unexpected_response", registrar: "OVH", body: existing)
          log_warn "Tentative de création du CNAME malgré tout..."
        end

        # Créer le CNAME
        post_url = "#{API_URL}/domain/zone/#{zone}/record"
        body     = %Q({"fieldType":"CNAME","subDomain":"#{subdomain}","target":"#{target}.","ttl":3600})
        ts       = `curl -s #{API_URL}/auth/time`.strip
        post_sig = sign(@app_secret, @consumer_key, "POST", post_url, body, ts)

        result = `curl -s -X POST \
          -H "Content-Type: application/json" \
          -H "X-Ovh-Application: #{@app_key}" \
          -H "X-Ovh-Consumer: #{@consumer_key}" \
          -H "X-Ovh-Timestamp: #{ts}" \
          -H "X-Ovh-Signature: $1$#{post_sig}" \
          -d '#{body}' "#{post_url}"`

        if result.includes?(%("id"))
          log_info I18n.t("dns.cname_created", sub: subdomain, zone: zone, target: target)
          refresh_zone(zone)
        else
          log_warn I18n.t("dns.unexpected_response", registrar: "OVH", body: result)
        end
      end

      # ── Privé ──────────────────────────────────────────────────────────────

      private def refresh_zone(zone : String) : Nil
        ts      = `curl -s #{API_URL}/auth/time`.strip
        ref_url = "#{API_URL}/domain/zone/#{zone}/refresh"
        ref_sig = sign(@app_secret, @consumer_key, "POST", ref_url, "", ts)

        `curl -s -X POST \
          -H "X-Ovh-Application: #{@app_key}" \
          -H "X-Ovh-Consumer: #{@consumer_key}" \
          -H "X-Ovh-Timestamp: #{ts}" \
          -H "X-Ovh-Signature: $1$#{ref_sig}" \
          "#{ref_url}"`

        log_info I18n.t("dns.zone_refreshed")
      end

      # Signature OVH : SHA1 SIMPLE (pas HMAC) sur la chaîne
      #   APP_SECRET+CONSUMER_KEY+METHOD+URL+BODY+TIMESTAMP
      #
      # L'API OVH utilise un hash SHA1 ordinaire (openssl dgst -sha1), PAS un HMAC.
      # Référence : table-de-gaya/config/deploy.sh, fonction ovh_sign()
      #   printf '%s+%s+%s+%s+%s+%s' secret ck method url body ts
      #     | openssl dgst -sha1 -hex | awk '{print $2}'
      #
      # sign_public est exposé pour les tests (même logique que sign).
      def sign_public(secret : String, consumer : String,
                      method : String, url : String,
                      body : String, ts : String) : String
        sign(secret, consumer, method, url, body, ts)
      end

      private def sign(secret : String, consumer : String,
                       method : String, url : String,
                       body : String, ts : String) : String
        data = "#{secret}+#{consumer}+#{method}+#{url}+#{body}+#{ts}"
        # openssl dgst -sha1 -hex retourne "SHA1(stdin)= <hex>" ou "(stdin)= <hex>"
        # On extrait le hash hexadécimal avec split sur les espaces
        raw = `printf '%s' #{Process.quote(data)} | openssl dgst -sha1 -hex`
        raw.strip.split(/\s+/).last
      end

      # ── État interne ───────────────────────────────────────────────────────

      @app_key      : String = ""
      @app_secret   : String = ""
      @consumer_key : String = ""
    end
  end
end
