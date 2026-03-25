module Aloli
  module Deploy
    class CLI
      include Logger

      USAGE = <<-USAGE
        Usage : deploy [commande] [--<env>]

        Commandes :
          init        Initialisation du serveur (une seule fois, idempotente)
          deploy      Déploiement d'une nouvelle release (défaut)
          rollback    Retour à la release précédente
          status      Afficher la version active et les releases disponibles
          generate-ci Générer le workflow GitHub Actions (.github/workflows/deploy.yml)
          ovh-setup   Créer et configurer les clés API OVH (sauvegarde dans .env)

        Options :
          --<env>     Nom de l'environnement défini dans config/deploy.yml (défaut: preproduction)
                      Les raccourcis par préfixe sont supportés :
                        --dev     → premier environnement dont le nom commence par "dev"
                        --prep    → premier environnement dont le nom commence par "prep"
                        --prod    → premier environnement dont le nom commence par "prod"

        Configuration :
          Le fichier config/deploy.yml doit définir :
            framework: marten | kemal   (adapte NGINX, migrations, CI)
            environments:
              developpement: ...
              preproduction: ...
              production: ...

        Exemples :
          deploy generate-ci
          deploy init --developpement       # ou raccourcis : --dev, --devel
          deploy init --preproduction       # ou raccourcis : --prep
          deploy deploy --preproduction     # ou raccourcis : --prep
          deploy deploy --production        # ou raccourcis : --prod
          deploy rollback --prod
          deploy status --prep
        USAGE

      def self.run(args : Array(String))
        new.run(args)
      end

      def run(args : Array(String))
        if args.empty? || args.includes?("--help") || args.includes?("-h")
          puts USAGE
          exit 0
        end

        # Commandes spéciales sans environnement
        if args.first == "generate-ci"
          config = Config.load
          Commands::GenerateCI.new(config).run
          exit 0
        end

        if args.first == "ovh-setup"
          config = Config.load
          Commands::OvhSetup.new(config).run
          exit 0
        end

        # Commande (premier argument, défaut : deploy)
        command = args.find { |arg| !arg.starts_with?("-") } || "deploy"
        
        # Résolution de l'environnement (argument --env, défaut : preproduction)
        env_arg = args.find { |arg| arg.starts_with?("--") } || "--preproduction"
        env_name = env_arg.lstrip('-')

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
          STDERR.puts "Commandes disponibles : init, deploy, rollback, status, generate-ci, ovh-setup".colorize(:yellow)
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
