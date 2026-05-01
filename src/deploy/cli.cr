module Deploy
  class CLI
    include Logger

    USAGE = <<-USAGE
      Usage : deploy [commande] [--<env>]

      Sans commande, `deploy` est implicite — invocation la plus courte :
        deploy                       # déploie sur la branche git courante
        deploy --production          # déploie sur l'env production

      Commandes :
        init        Initialisation du serveur (une seule fois, idempotente)
        deploy      Déploiement d'une nouvelle release (défaut implicite)
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
                    Sans --<env>, l'environnement est déduit de la branche git courante.

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
        deploy                              # deploy implicite, env = branche courante
        deploy --production                 # deploy explicite sur --production
        deploy init --developpement
        deploy rollback --prod
        deploy status --prep
        deploy dns-setup --developpement    # configurer les clés DNS
        deploy generate-ci                  # générer le workflow GitHub Actions
      USAGE

    def self.run(args : Array(String))
      new.run(args)
    end

    # Résout la commande à exécuter à partir des arguments bruts CLI.
    # Renvoie le premier argument qui ne commence pas par `-` ; sinon
    # `"deploy"` (commande par défaut, déclarée dans USAGE). Méthode
    # pure et publique pour permettre les tests unitaires.
    def self.resolve_command(args : Array(String)) : String
      args.find { |arg| !arg.starts_with?("-") } || "deploy"
    end

    DEPLOY_YML_EXAMPLE = {{ read_file("#{__DIR__}/../../examples/marten/config/deploy.yml") }}

    def run(args : Array(String))
      if args.includes?("--help") || args.includes?("-h")
        puts USAGE
        exit 0
      end

      # Sans config/deploy.yml local on n'a rien à déployer : on imprime
      # l'aide et on génère un gabarit pour amorcer un nouveau projet.
      # Toute autre invocation tombe sur la commande `deploy` par défaut
      # (cf. ligne `command = ... || "deploy"` plus bas), avec
      # auto-détection de l'environnement depuis la branche git courante
      # si `--<env>` n'est pas fourni.
      unless File.exists?("config/deploy.yml")
        puts USAGE
        generate_deploy_yml_example
        exit 0
      end

      # Commande generate-ci : sans environnement
      if args.first? == "generate-ci"
        config = Config.load
        Commands::GenerateCI.new(config).run
        exit 0
      end

      # Résolution de l'environnement
      env_arg = args.find { |arg| arg.starts_with?("--") }
      config = Config.load

      env_name = if env_arg
                   env_arg.lstrip('-')
                 else
                   resolve_env_from_branch(config)
                 end
      env = resolve_environment(config, env_name)

      # Commande dns-setup : configure les clés du registrar DNS
      if args.first? == "dns-setup"
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

      # Commande principale (cf. CLI.resolve_command).
      command = CLI.resolve_command(args)

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

    private def generate_deploy_yml_example
      dest = "config/deploy.yml"
      if File.exists?(dest)
        puts "\n[INFO] #{dest} existe déjà — non modifié.".colorize(:cyan)
      else
        Dir.mkdir_p("config")
        File.write(dest, DEPLOY_YML_EXAMPLE)
        puts "\n[OK] #{dest} généré — adaptez-le à votre projet puis relancez :\n     bin/deploy init --<env>".colorize(:green)
      end
    end

    # Détecte la branche git courante et cherche l'environnement correspondant.
    private def resolve_env_from_branch(config : Config) : String
      branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
      if branch.empty?
        STDERR.puts "Impossible de détecter la branche git courante.".colorize(:red)
        STDERR.puts "Spécifiez l'environnement avec --<env>.".colorize(:yellow)
        exit 1
      end

      match = config.environments.find { |_, env| env.branch == branch }
      if match
        log_info "Branche #{branch.colorize(:white)} → environnement #{match[0].colorize(:white)}"
        match[0]
      else
        STDERR.puts "Aucun environnement ne correspond à la branche '#{branch}'.".colorize(:red)
        STDERR.puts "Branches configurées : #{config.environments.map { |k, v| "#{k} (#{v.branch})" }.join(", ")}".colorize(:yellow)
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
