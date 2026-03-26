module CrystalDeploy
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
        dns-setup   Configurer les clés du registrar DNS (sauvegarde dans .env local)

      Options :
        --<env>     Nom de l'environnement défini dans config/deploy.yml
                    Les raccourcis par préfixe sont supportés :
                      --dev     → premier environnement dont le nom commence par "dev"
                      --prep    → premier environnement dont le nom commence par "prep"
                      --prod    → premier environnement dont le nom commence par "prod"

      Configuration :
        config/deploy.yml doit définir :
          framework: marten | kemal
          database:  postgresql | sqlite | none
          dns:
            registrar: ovh
            zone: example.app
          environments:
            developpement: ...
            production: ...

      Exemples :
        deploy dns-setup --developpement    # configurer les clés DNS
        deploy generate-ci                  # générer le workflow GitHub Actions
        deploy init --developpement
        deploy deploy --production
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

      # Commande generate-ci : sans environnement
      if args.first == "generate-ci"
        config = Config.load
        Commands::GenerateCI.new(config).run
        exit 0
      end

      # Résolution de l'environnement
      env_arg  = args.find { |arg| arg.starts_with?("--") } || "--preproduction"
      env_name = env_arg.lstrip('-')
      config   = Config.load
      env      = resolve_environment(config, env_name)

      # Commande dns-setup : configure les clés du registrar DNS
      if args.first == "dns-setup"
        registrar = config.dns_registrar
        unless registrar
          log_warn "Aucun registrar DNS configuré dans config/deploy.yml (champ dns.registrar)."
          exit 1
        end
        dns = DNS::Factory.for(registrar, config, env)
        if dns
          dns.load_credentials
          if dns.credentials_present?
            log_info I18n.t("dns.keys_found", registrar: registrar.upcase)
          else
            dns.help_generate_keys(config.dns_zone || env.dns_zone)
            if confirm?(I18n.t("dns.keys_ready"))
              dns.ask_credentials
              dns.save_credentials
            end
          end
        end
        exit 0
      end

      # Commande principale
      command = args.find { |arg| !arg.starts_with?("-") } || "deploy"

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
        STDERR.puts I18n.t("errors.unknown_env", name: command).colorize(:red)
        STDERR.puts "Commandes disponibles : init, deploy, rollback, status, generate-ci, dns-setup".colorize(:yellow)
        exit 1
      end
    end

    private def resolve_environment(config : Config, name : String) : Environment
      return config.environment(name) if config.environments.has_key?(name)

      matches = config.environments.keys.select { |k| k.starts_with?(name) }
      if matches.size == 1
        return config.environment(matches.first)
      elsif matches.size > 1
        STDERR.puts "Environnement ambigu '#{name}' : #{matches.join(", ")}".colorize(:red)
        exit 1
      end

      config.environment(name)
    end
  end
end
