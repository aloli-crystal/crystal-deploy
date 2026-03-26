module CrystalDeploy
  module DNS
    # Interface abstraite pour la gestion DNS.
    # Chaque registrar implémente cette classe.
    #
    # Pour ajouter un registrar :
    #   1. Créer dns/mon_registrar.cr héritant de DNS::Base
    #   2. Implémenter les méthodes abstraites
    #   3. L'enregistrer dans DNS::Factory
    abstract class Base
      include Logger

      def initialize(@config : Config, @env : Environment)
      end

      # Retourne true si les credentials sont déjà disponibles
      # (variables d'environnement, fichier .env local, etc.)
      abstract def credentials_present? : Bool

      # Charge les credentials depuis les sources disponibles
      # (variables d'environnement en priorité, puis .env local)
      abstract def load_credentials : Nil

      # Demande les credentials à l'utilisateur de façon interactive
      abstract def ask_credentials : Nil

      # Sauvegarde les credentials dans le .env local
      abstract def save_credentials : Nil

      # Affiche le guide de génération des clés pour ce registrar
      abstract def help_generate_keys(zone : String) : Nil

      # Crée ou vérifie un enregistrement CNAME
      abstract def create_cname(subdomain : String, target : String, zone : String) : Nil

      # Point d'entrée principal : appelé par `init`
      # Gère le flux complet : chargement credentials → dialogue → création CNAME
      def setup : Nil
        subdomain = @env.effective_dns_subdomain
        target    = @env.effective_dns_target
        zone      = @config.dns_zone || @env.dns_zone

        return if subdomain.empty? || target.empty?

        log_section I18n.t("dns.section")

        load_credentials

        if credentials_present?
          log_info I18n.t("dns.keys_found", registrar: registrar_name)
          return unless confirm?(I18n.t("dns.confirm_cname",
            sub: subdomain, zone: zone, target: target))
          create_cname(subdomain, target, zone)
          return
        end

        return unless confirm?(I18n.t("dns.configure_now", registrar: registrar_name))

        help_generate_keys(zone)
        return unless confirm?(I18n.t("dns.keys_ready"))

        ask_credentials
        save_credentials
        create_cname(subdomain, target, zone)
      end

      # Nom du registrar (pour les messages)
      abstract def registrar_name : String
    end

    # Factory : instancie le bon registrar selon la configuration
    module Factory
      def self.for(registrar : String?, config : Config, env : Environment) : Base?
        return nil if registrar.nil? || registrar.empty?

        case registrar.downcase
        when "ovh"
          Ovh.new(config, env)
        when "gandi"
          Gandi.new(config, env)
        else
          STDERR.puts I18n.t("errors.unknown_registrar", name: registrar).colorize(:red)
          exit 1
        end
      end
    end
  end
end
