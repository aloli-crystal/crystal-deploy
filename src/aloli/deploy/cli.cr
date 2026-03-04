module Aloli
  module Deploy
    class CLI
      include Logger

      USAGE = <<-USAGE
        Usage : deploy --<env> [commande]

        Options :
          --<env>     Nom de l'environnement défini dans config/deploy.yml
                      Exemples : --developpement, --production, --dev

        Commandes :
          init        Initialisation du serveur (une seule fois, idempotente)
          deploy      Déploiement d'une nouvelle release (défaut)
          rollback    Retour à la release précédente
          status      Afficher la version active et les releases disponibles

        Exemples :
          deploy --developpement init
          deploy --production deploy
          deploy --production rollback
          deploy --dev status
        USAGE

      def self.run(args : Array(String))
        new.run(args)
      end

      def run(args : Array(String))
        if args.empty? || args.first == "--help" || args.first == "-h"
          puts USAGE
          exit 0
        end

        # Résolution de l'environnement (premier argument : --env-name)
        env_arg = args.shift
        unless env_arg.starts_with?("--")
          STDERR.puts "Erreur : le premier argument doit être --<environnement>".colorize(:red)
          puts USAGE
          exit 1
        end
        env_name = env_arg.lstrip('-')

        # Commande (deuxième argument, défaut : deploy)
        command = args.shift? || "deploy"

        # Chargement de la configuration
        config = Config.load

        # Résolution de l'environnement (support des alias courts : dev → developpement)
        env = resolve_environment(config, env_name)

        case command
        when "init"
          Commands::Init.new(config, env).run
        when "deploy"
          Commands::Deploy.new(config, env).run
        when "rollback"
          Commands::Rollback.new(config, env).run
        when "status"
          Commands::Status.new(config, env).run
        else
          STDERR.puts "Commande inconnue : #{command}".colorize(:red)
          STDERR.puts "Commandes disponibles : init, deploy, rollback, status".colorize(:yellow)
          exit 1
        end
      end

      private def resolve_environment(config : Config, name : String) : Environment
        # Essai direct
        return config.environment(name) if config.environments.has_key?(name)

        # Essai par préfixe (ex: "dev" → "developpement")
        matches = config.environments.keys.select { |k| k.starts_with?(name) }
        if matches.size == 1
          return config.environment(matches.first)
        elsif matches.size > 1
          STDERR.puts "Environnement ambigu '#{name}' : #{matches.join(", ")}".colorize(:red)
          exit 1
        end

        config.environment(name) # déclenche l'erreur standard
      end
    end
  end
end
