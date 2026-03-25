require "http/client"
require "json"

module Aloli
  module Deploy
    module Commands
      class OvhSetup
        include Logger

        OVH_API_URL    = "https://eu.api.ovh.com/1.0"
        OVH_CREATE_APP = "https://eu.api.ovh.com/createApp/"
        ENV_FILE       = ".env"

        def initialize(@config : Config)
        end

        def run
          log_info "=== Configuration des clés API OVH ==="
          puts
          puts "Ce guide va vous aider à créer et configurer les clés API OVH".colorize(:cyan)
          puts "nécessaires pour la gestion automatique des DNS lors du déploiement.".colorize(:cyan)
          puts

          # Étape 1 : vérifier si des clés existent déjà
          existing = load_existing_keys
          if existing[:app_key] && existing[:app_secret] && existing[:consumer_key]
            puts "Des clés OVH sont déjà présentes dans votre #{ENV_FILE} :".colorize(:yellow)
            puts "  OVH_APP_KEY      = #{mask(existing[:app_key].not_nil!)}"
            puts "  OVH_APP_SECRET   = #{mask(existing[:app_secret].not_nil!)}"
            puts "  OVH_CONSUMER_KEY = #{mask(existing[:consumer_key].not_nil!)}"
            puts
            print "Voulez-vous les remplacer ? [o/N] : "
            answer = STDIN.gets.try(&.strip.downcase) || "n"
            return unless answer == "o" || answer == "oui"
            puts
          end

          # Étape 2 : créer l'application OVH
          step1_create_app

          print "Entrez votre Application Key (OVH_APP_KEY) : "
          app_key = STDIN.gets.try(&.strip) || ""
          abort "Application Key vide, abandon.".colorize(:red).to_s if app_key.empty?

          print "Entrez votre Application Secret (OVH_APP_SECRET) : "
          app_secret = STDIN.gets.try(&.strip) || ""
          abort "Application Secret vide, abandon.".colorize(:red).to_s if app_secret.empty?

          # Étape 3 : générer le Consumer Key
          puts
          consumer_key, validation_url = step2_generate_consumer_key(app_key, app_secret)

          # Étape 4 : validation dans le navigateur
          step3_validate(validation_url)

          # Étape 5 : sauvegarder dans .env
          save_to_env(app_key, app_secret, consumer_key)

          puts
          log_success "Clés OVH configurées et sauvegardées dans #{ENV_FILE}"
          puts
          puts "Vous pouvez maintenant utiliser la création automatique de CNAME DNS".colorize(:cyan)
          puts "en ajoutant dns_subdomain et dns_target dans vos environnements.".colorize(:cyan)
        end

        private def step1_create_app
          puts "┌─────────────────────────────────────────────────────────────┐".colorize(:blue)
          puts "│  Étape 1 — Créer l'application OVH                          │".colorize(:blue)
          puts "└─────────────────────────────────────────────────────────────┘".colorize(:blue)
          puts
          puts "Ouvrez l'URL suivante dans votre navigateur pour créer l'application :"
          puts
          puts "  #{OVH_CREATE_APP}".colorize(:cyan).underline
          puts
          puts "Renseignez :"
          puts "  - Application name    : #{@config.app_name}"
          puts "  - Application description : Déploiement #{@config.app_name}"
          puts
          puts "Vous obtiendrez une Application Key et un Application Secret.".colorize(:yellow)
          puts
          print "Appuyez sur Entrée une fois l'application créée..."
          STDIN.gets
          puts
        end

        private def step2_generate_consumer_key(app_key : String, app_secret : String) : Tuple(String, String)
          puts "┌─────────────────────────────────────────────────────────────┐".colorize(:blue)
          puts "│  Étape 2 — Générer le Consumer Key                          │".colorize(:blue)
          puts "└─────────────────────────────────────────────────────────────┘".colorize(:blue)
          puts
          puts "Génération du Consumer Key via l'API OVH...".colorize(:cyan)

          dns_zone = @config.ovh_dns_zone

          body = {
            "accessRules" => [
              {"method" => "GET",  "path" => "/domain/zone/#{dns_zone}"},
              {"method" => "GET",  "path" => "/domain/zone/#{dns_zone}/record"},
              {"method" => "POST", "path" => "/domain/zone/#{dns_zone}/record"},
              {"method" => "POST", "path" => "/domain/zone/#{dns_zone}/refresh"},
              {"method" => "GET",  "path" => "/domain/zone/#{dns_zone}/record/*"},
              {"method" => "DELETE","path" => "/domain/zone/#{dns_zone}/record/*"},
            ],
            "redirection" => "https://www.ovhcloud.com/fr/",
          }.to_json

          response = HTTP::Client.post(
            "#{OVH_API_URL}/auth/credential",
            headers: HTTP::Headers{
              "Content-Type"    => "application/json",
              "X-Ovh-Application" => app_key,
            },
            body: body
          )

          unless response.status_code == 200
            abort "Erreur API OVH (#{response.status_code}) : #{response.body}".colorize(:red).to_s
          end

          data = JSON.parse(response.body)
          consumer_key    = data["consumerKey"].as_s
          validation_url  = data["validationUrl"].as_s

          puts
          puts "Consumer Key généré : #{consumer_key}".colorize(:green)
          puts

          {consumer_key, validation_url}
        end

        private def step3_validate(validation_url : String)
          puts "┌─────────────────────────────────────────────────────────────┐".colorize(:blue)
          puts "│  Étape 3 — Valider les droits dans votre espace OVH         │".colorize(:blue)
          puts "└─────────────────────────────────────────────────────────────┘".colorize(:blue)
          puts
          puts "Ouvrez l'URL suivante dans votre navigateur pour valider les droits DNS :".colorize(:yellow)
          puts
          puts "  #{validation_url}".colorize(:cyan).underline
          puts
          puts "Connectez-vous avec votre compte OVH et cliquez sur « Valider ».".colorize(:yellow)
          puts
          print "Appuyez sur Entrée une fois la validation effectuée..."
          STDIN.gets
          puts
        end

        private def save_to_env(app_key : String, app_secret : String, consumer_key : String)
          puts "┌─────────────────────────────────────────────────────────────┐".colorize(:blue)
          puts "│  Étape 4 — Sauvegarde dans #{ENV_FILE.ljust(33)}│".colorize(:blue)
          puts "└─────────────────────────────────────────────────────────────┘".colorize(:blue)
          puts

          env_path = ENV_FILE
          lines = File.exists?(env_path) ? File.read_lines(env_path) : [] of String

          # Supprimer les anciennes clés OVH si présentes
          lines.reject! { |l| l.starts_with?("OVH_APP_KEY=") || l.starts_with?("OVH_APP_SECRET=") || l.starts_with?("OVH_CONSUMER_KEY=") }

          # Ajouter un séparateur si le fichier n'est pas vide
          unless lines.empty? || lines.last.strip.empty?
            lines << ""
          end

          lines << "# Clés API OVH — NE PAS VERSIONNER"
          lines << "OVH_APP_KEY=#{app_key}"
          lines << "OVH_APP_SECRET=#{app_secret}"
          lines << "OVH_CONSUMER_KEY=#{consumer_key}"

          File.write(env_path, lines.join("\n") + "\n")
          File.chmod(env_path, 0o600)

          puts "Clés sauvegardées dans #{env_path} (permissions 600).".colorize(:green)
          puts
          puts "Vérifiez que #{env_path} est bien dans votre .gitignore :".colorize(:yellow)
          puts "  echo '.env' >> .gitignore"
        end

        private def load_existing_keys : NamedTuple(app_key: String?, app_secret: String?, consumer_key: String?)
          app_key = app_secret = consumer_key = nil

          # Depuis le .env local
          if File.exists?(ENV_FILE)
            File.each_line(ENV_FILE) do |line|
              line = line.strip
              next if line.starts_with?("#") || line.empty?
              key, _, value = line.partition("=")
              case key.strip
              when "OVH_APP_KEY"      then app_key      = value.strip
              when "OVH_APP_SECRET"   then app_secret   = value.strip
              when "OVH_CONSUMER_KEY" then consumer_key = value.strip
              end
            end
          end

          # Depuis les variables d'environnement shell
          app_key      ||= ENV["OVH_APP_KEY"]?
          app_secret   ||= ENV["OVH_APP_SECRET"]?
          consumer_key ||= ENV["OVH_CONSUMER_KEY"]?

          {app_key: app_key, app_secret: app_secret, consumer_key: consumer_key}
        end

        private def mask(value : String) : String
          return value if value.size <= 4
          value[0..3] + "*" * (value.size - 4)
        end
      end
    end
  end
end
