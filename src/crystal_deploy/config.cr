module CrystalDeploy
  # ─── Environnement de déploiement ─────────────────────────────────────────
  # Représente un environnement défini dans config/deploy.yml
  class Environment
    include YAML::Serializable

    property branch : String
    property host : String
    property user : String
    property app_url : String

    # Sous-domaine DNS explicite (optionnel — calculé depuis app_url si absent)
    property dns_subdomain : String? = nil

    # Cible du CNAME (optionnel — utilise `host` si absent, avec point final ajouté)
    property dns_target : String? = nil

    # Nom injecté après désérialisation (clé du hash environments:)
    @[YAML::Field(ignore: true)]
    property name : String = ""

    # Nom complet : app-name--env-name
    def full_name(app_name : String) : String
      "#{app_name}--#{name}"
    end

    # Répertoire home de l'application sur le serveur
    def app_home(app_name : String) : String
      "/home/#{full_name(app_name)}"
    end

    # Chemin du socket Unix (convention /tmp)
    def socket_path(app_name : String) : String
      "/tmp/.#{full_name(app_name)}.sock"
    end

    # Chemin du pidfile
    def pid_path(app_name : String) : String
      "/tmp/.#{full_name(app_name)}.pid"
    end

    # Nom du service rc.d (tirets → underscores, -- → __)
    def service_rc_name(app_name : String) : String
      full_name(app_name).tr("-", "_")
    end

    # Hostname extrait de app_url (sans le schéma https://)
    def hostname : String
      app_url.sub(/^https?:\/\//, "")
    end

    # Sous-domaine DNS effectif : valeur explicite ou premier label du hostname
    def effective_dns_subdomain : String
      dns_subdomain || hostname.split(".").first
    end

    # Cible CNAME effective : valeur explicite ou host avec point final
    def effective_dns_target : String
      t = dns_target || "#{host}."
      t.ends_with?(".") ? t : "#{t}."
    end

    # Zone DNS calculée depuis app_url (tout sauf le premier label)
    def dns_zone : String
      parts = hostname.split(".")
      parts.size > 1 ? parts[1..].join(".") : hostname
    end
  end

  # ─── Configuration DNS ──────────────────────────────────────────────────
  # Optionnelle — absente si pas de gestion DNS automatique
  # Accepte `zone` ou `dns_zone` comme alias pour la zone DNS.
  # Les commentaires inline YAML (# ...) sur `registrar` sont nettoyés automatiquement.
  class DnsConfig
    include YAML::Serializable

    property registrar : String   # ovh | gandi
    property zone : String        # zone DNS gérée (ex: example.app)

    # Alias de zone pour la compatibilité avec les méthodes appelantes
    def effective_zone : String
      zone
    end
  end

  # ─── Définition d'une variable obligatoire ─────────────────────────────────
  # Lue depuis config/env_vars.yml (section `required`)
  class EnvVarDef
    include YAML::Serializable

    property key : String
    property secret : Bool = false
    # Génération automatique si vide : hex32 | hex64 | password
    property generate : String? = nil
  end

  # ─── Règles des variables d'environnement ──────────────────────────────────
  # Lues depuis config/env_vars.yml du shard
  class EnvVarsConfig
    include YAML::Serializable

    property required : Array(EnvVarDef) = [] of EnvVarDef
    property skip : Array(String) = [] of String

    # Charge depuis un fichier YAML
    def self.load(path : String) : EnvVarsConfig
      if File.exists?(path)
        EnvVarsConfig.from_yaml(File.read(path))
      else
        EnvVarsConfig.new
      end
    end

    def initialize
      @required = [] of EnvVarDef
      @skip = [] of String
    end

    # Retourne true si la variable doit être ignorée dans le dialogue
    def skip?(key : String) : Bool
      @skip.includes?(key)
    end
  end

  # ─── Variable lue depuis .env.example ──────────────────────────────────────
  # Représente une ligne du .env.example du projet (section optionnelle du dialogue)
  struct EnvExampleVar
    property key : String
    property comment : String

    def initialize(@key, @comment = "")
    end
  end

  # ─── Configuration principale ──────────────────────────────────────────────
  # Lue depuis config/deploy.yml du projet
  class Config
    include YAML::Serializable

    property app_name : String
    property repo_url : String
    property crystal_main : String
    property crystal_flags : String? = nil
    property keep_releases : Int32 = 10

    # Framework : marten | kemal
    property framework : String = "kemal"

    # Base de données : postgresql | sqlite | none
    property database : String = "postgresql"

    # Configuration DNS (optionnelle)
    property dns : DnsConfig? = nil

    property environments : Hash(String, Environment)

    # ── Méthodes de commodité ──────────────────────────────────────────────

    def marten? : Bool
      framework.downcase == "marten"
    end

    def kemal? : Bool
      framework.downcase == "kemal"
    end

    def dns_registrar : String?
      dns.try(&.registrar)
    end

    def dns_zone : String?
      dns.try(&.zone)
    end

    # ── Chargement ────────────────────────────────────────────────────────────

    # Charge config/deploy.yml depuis le répertoire courant
    def self.load(path : String = "config/deploy.yml") : Config
      unless File.exists?(path)
        STDERR.puts "Erreur : fichier de configuration introuvable : #{path}".colorize(:red)
        STDERR.puts "Créez config/deploy.yml à partir des exemples dans examples/".colorize(:yellow)
        exit 1
      end

      config = Config.from_yaml(File.read(path))
      config.environments.each { |name, env| env.name = name }
      config
    end

    # Retourne l'environnement demandé ou quitte avec un message d'erreur
    def environment(name : String) : Environment
      env = environments[name]?
      unless env
        STDERR.puts "Environnement inconnu : #{name}".colorize(:red)
        STDERR.puts "Environnements disponibles : #{environments.keys.join(", ")}".colorize(:yellow)
        exit 1
      end
      env
    end

    # ── Lecture de .env.example ───────────────────────────────────────────────
    # Retourne les variables présentes dans .env.example qui ne sont pas dans
    # la liste `skip` de env_vars.yml et pas déjà dans `already_defined`.
    # Utilisé pour la section optionnelle du dialogue `init`.
    def load_env_example(
      path : String,
      skip_keys : Array(String),
      already_defined : Array(String)
    ) : Array(EnvExampleVar)
      return [] of EnvExampleVar unless File.exists?(path)

      vars = [] of EnvExampleVar
      pending_comment = ""

      File.each_line(path) do |line|
        stripped = line.strip

        if stripped.empty?
          pending_comment = ""
          next
        end

        if stripped.starts_with?("#")
          # Extraire le texte du commentaire (sans le #)
          text = stripped.lstrip('#').strip
          # Ignorer les séparateurs de section (─── ... ───)
          next if text.includes?("─")
          # Ignorer les lignes de commande shell indentées (ex: #   crystal eval)
          next if text.starts_with?("crystal ") || text.starts_with?("marten ") ||
                  text.starts_with?("bin/") || text.starts_with?("./")
          # Ignorer les marqueurs [auto], [db], [test], [généré]
          next if text.starts_with?("[")
          pending_comment = text
          next
        end

        if stripped.includes?("=")
          key, _, _value = stripped.partition("=")
          key = key.strip
          next if skip_keys.includes?(key)
          next if already_defined.includes?(key)
          vars << EnvExampleVar.new(key: key, comment: pending_comment)
          pending_comment = ""
        end
      end

      vars
    end
  end
end
