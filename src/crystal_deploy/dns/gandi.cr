module CrystalDeploy
  module DNS
    # Implémentation Gandi de l'interface DNS.
    # Utilise l'API Gandi LiveDNS v5 avec authentification PAT
    # (Personal Access Token).
    #
    # Endpoint : https://api.gandi.net/v5/livedns
    # Documentation : https://api.gandi.net/docs/livedns/
    #
    # Credential lu dans cet ordre de priorité :
    #   1. Variable d'environnement : GANDI_PAT
    #   2. Fichier .env local (LOCAL_ENV_PATH)
    class Gandi < Base
      LOCAL_ENV_PATH = ".env"
      API_URL        = "https://api.gandi.net/v5/livedns"

      def registrar_name : String
        "Gandi"
      end

      def credentials_present? : Bool
        !@pat.empty?
      end

      def load_credentials : Nil
        # Source 1 : variable d'environnement
        @pat = ENV.fetch("GANDI_PAT", "")
        return if credentials_present?

        # Source 2 : .env local
        if File.exists?(@local_env_path)
          File.each_line(@local_env_path) do |line|
            next if line.strip.starts_with?("#") || line.strip.empty?
            k, _, v = line.partition("=")
            @pat = v.strip if k.strip == "GANDI_PAT" && @pat.empty?
          end
        end
      end

      def ask_credentials : Nil
        @pat = ask(I18n.t("dns.key_pat") + " : ")
      end

      def save_credentials : Nil
        env_path = LOCAL_ENV_PATH
        existing = File.exists?(env_path) ? File.read_lines(env_path) : [] of String

        filtered = existing.reject { |l| l.starts_with?("GANDI_PAT=") }
        filtered << "" unless filtered.empty? || filtered.last.strip.empty?
        filtered << "# Personal Access Token Gandi — NE PAS VERSIONNER"
        filtered << "GANDI_PAT=#{@pat}"
        filtered << ""

        File.write(env_path, filtered.join("\n"))
        File.chmod(env_path, 0o600)
        log_local I18n.t("dns.saved", path: env_path)
        log_warn I18n.t("dns.check_gitignore", path: env_path)
      end

      def help_generate_keys(zone : String) : Nil
        puts ""
        puts "╔══════════════════════════════════════════════════════╗".colorize(:cyan).bold
        puts "║         Génération du Personal Access Token Gandi    ║".colorize(:cyan).bold
        puts "╚══════════════════════════════════════════════════════╝".colorize(:cyan).bold
        puts ""
        puts I18n.t("dns.gandi_step1")
        puts I18n.t("dns.gandi_step2")
        puts I18n.t("dns.gandi_step3")
        puts ""
        puts I18n.t("dns.keys_saved_in")
        puts ""
      end

      def create_cname(subdomain : String, target : String, zone : String) : Nil
        log_section "CNAME : #{subdomain}.#{zone} → #{target}"

        unless Process.find_executable("curl")
          log_warn "curl introuvable. Créez le CNAME manuellement dans votre espace Gandi."
          return
        end

        # Vérifier si le CNAME existe déjà
        get_url = "#{API_URL}/domains/#{zone}/records/#{subdomain}/CNAME"
        existing = `curl -s -o /dev/null -w "%{http_code}" \
          -H "Authorization: Bearer #{@pat}" \
          "#{get_url}"`

        if existing.strip == "200"
          log_info I18n.t("dns.cname_exists", sub: subdomain, zone: zone)
          return
        end

        # Créer le CNAME
        # POST /v5/livedns/domains/{fqdn}/records/{rrset_name}/CNAME
        post_url = "#{API_URL}/domains/#{zone}/records/#{subdomain}/CNAME"
        body     = %Q({"rrset_values":["#{target}."],"rrset_ttl":3600})

        result = `curl -s -X POST \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer #{@pat}" \
          -d '#{body}' "#{post_url}"`

        if result.empty? || result.includes?(%("message")) && !result.includes?("error")
          log_info I18n.t("dns.cname_created", sub: subdomain, zone: zone, target: target)
        elsif result.empty?
          log_info I18n.t("dns.cname_created", sub: subdomain, zone: zone, target: target)
        else
          log_warn I18n.t("dns.unexpected_response", registrar: "Gandi", body: result)
        end
      end

      # ── État interne ───────────────────────────────────────────────────────

      property local_env_path : String = LOCAL_ENV_PATH
      @pat : String = ""
    end
  end
end
