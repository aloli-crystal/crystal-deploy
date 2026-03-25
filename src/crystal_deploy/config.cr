module CrystalDeploy
  # Représente un environnement de déploiement (developpement, preproduction, production, etc.)
  class Environment
    include YAML::Serializable

    property branch : String
    property host : String
    property user : String
    property app_url : String

    # Dérivés (calculés, non sérialisés)
    @[YAML::Field(ignore: true)]
    property name : String = ""

    # Nom complet de l'application pour cet environnement : app-name--env
    def full_name(app_name : String) : String
      "#{app_name}--#{name}"
    end

    # Répertoire home de l'application sur le serveur
    def app_home(app_name : String) : String
      "/home/#{full_name(app_name)}"
    end

    # Chemin du socket Unix de l'application (convention /tmp)
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

    # Sous-domaine DNS déduit du hostname (premier label)
    def dns_subdomain : String
      hostname.split(".").first
    end

    # Zone DNS déduite du hostname (tout sauf le premier label)
    def dns_zone : String
      parts = hostname.split(".")
      parts.size > 1 ? parts[1..].join(".") : hostname
    end

    # Cible DNS (hostname du serveur, utilisé pour le CNAME)
    # Peut être surchargée dans deploy.yml si le serveur a un nom différent
    @[YAML::Field(ignore: true)]
    property dns_target : String? = nil

    def resolved_dns_target : String
      dns_target || host
    end
  end

  # Framework supporté : marten ou kemal (défaut : kemal pour compatibilité ascendante)
  enum Framework
    Kemal
    Marten

    def self.from_string(s : String) : Framework
      case s.downcase
      when "marten" then Marten
      when "kemal"  then Kemal
      else
        STDERR.puts "Framework inconnu : '#{s}'. Valeurs acceptées : marten, kemal".colorize(:red)
        exit 1
      end
    end
  end

  # Variable d'environnement découverte dans .env.example
  # Représente une ligne du fichier avec son commentaire et sa valeur par défaut
  struct EnvExampleVar
    property key : String
    property default_value : String
    property comment : String
    property is_secret : Bool
    property is_generated : Bool  # clé à générer automatiquement (SECRET_KEY, etc.)
    property is_pg : Bool         # variable construite depuis le dialogue PostgreSQL
    property is_marten_auto : Bool # variable injectée automatiquement par le shard

    def initialize(@key, @default_value = "", @comment = "",
                   @is_secret = false, @is_generated = false,
                   @is_pg = false, @is_marten_auto = false)
    end
  end

  # Configuration principale lue depuis config/deploy.yml
  # Contient uniquement les informations d'infrastructure (pas de secrets, pas de variables .env)
  class Config
    include YAML::Serializable

    property app_name : String
    property repo_url : String
    property crystal_main : String
    property crystal_flags : String? = nil
    property keep_releases : Int32 = 10
    property framework : String = "kemal"   # marten | kemal
    property environments : Hash(String, Environment)

    # Retourne l'enum Framework correspondant
    def framework_enum : Framework
      Framework.from_string(framework)
    end

    def marten? : Bool
      framework_enum == Framework::Marten
    end

    def kemal? : Bool
      framework_enum == Framework::Kemal
    end

    # URL de l'API OVH (toujours la même pour les clients européens)
    def ovh_api_url : String
      "https://eu.api.ovh.com/1.0"
    end

    # Charge la configuration depuis un fichier YAML
    def self.load(path : String = "config/deploy.yml") : Config
      unless File.exists?(path)
        STDERR.puts "Erreur : fichier de configuration introuvable : #{path}".colorize(:red)
        STDERR.puts "Créez config/deploy.yml à partir de l'exemple fourni par le shard.".colorize(:yellow)
        exit 1
      end

      config = Config.from_yaml(File.read(path))

      # Injecter le nom dans chaque objet Environment
      config.environments.each do |name, env|
        env.name = name
      end

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

    # ─── Lecture de .env.example ─────────────────────────────────────────────
    #
    # Le shard découvre les variables à demander lors du `init` en lisant
    # le fichier .env.example du projet. Ce fichier est la source de vérité
    # pour les variables d'environnement de l'application.
    #
    # Convention de .env.example :
    #   # Commentaire sur la variable suivante
    #   CLE=valeur_par_defaut
    #   CLE_SECRETE=           ← valeur vide = secret, demander à l'utilisateur
    #   SECRET_KEY=            ← détecté comme "à générer" par le nom
    #   # [généré]             ← commentaire spécial : génération automatique
    #   # [postgresql]         ← commentaire spécial : construit par le dialogue PG
    #
    # Variables Marten injectées automatiquement (non demandées) :
    #   MARTEN_ENV, MARTEN_ALLOWED_HOSTS, MARTEN_SOCKET
    #
    MARTEN_AUTO_VARS = %w[MARTEN_ENV MARTEN_ALLOWED_HOSTS MARTEN_SOCKET]
    PG_VARS_MARTEN   = %w[DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME]
    PG_VARS_KEMAL    = %w[DATABASE_URL]
    GENERATED_KEYS   = %w[SECRET_KEY]

    def load_env_example(path : String = ".env.example") : Array(EnvExampleVar)
      unless File.exists?(path)
        return default_env_vars
      end

      vars = [] of EnvExampleVar
      pending_comment = ""

      File.each_line(path) do |line|
        stripped = line.strip

        # Ligne vide : réinitialise le commentaire en attente
        if stripped.empty?
          pending_comment = ""
          next
        end

        # Ligne de commentaire
        if stripped.starts_with?("#")
          pending_comment = stripped.lstrip('#').strip
          next
        end

        # Ligne de variable : CLE=valeur
        if stripped.includes?("=")
          key, _, value = stripped.partition("=")
          key = key.strip

          is_marten_auto = MARTEN_AUTO_VARS.includes?(key)
          is_pg = if marten?
            PG_VARS_MARTEN.includes?(key)
          else
            PG_VARS_KEMAL.includes?(key)
          end
          is_generated = GENERATED_KEYS.includes?(key) ||
                         pending_comment.downcase.includes?("[généré") ||
                         pending_comment.downcase.includes?("[genere")
          is_secret = value.strip.empty? ||
                      key.downcase.includes?("secret") ||
                      key.downcase.includes?("password") ||
                      key.downcase.includes?("token") ||
                      (key.downcase.includes?("key") && !key.starts_with?("STRIPE_PK"))

          vars << EnvExampleVar.new(
            key: key,
            default_value: value.strip,
            comment: pending_comment,
            is_secret: is_secret,
            is_generated: is_generated,
            is_pg: is_pg,
            is_marten_auto: is_marten_auto
          )
          pending_comment = ""
        end
      end

      vars
    end

    # ─── Lecture du .env local ──────────────────────────────────────────────────
    #
    # Lors du `init`, si un fichier .env local existe déjà (par exemple après
    # un premier `init` ou une copie manuelle), le shard lit les valeurs
    # existantes pour pré-remplir le dialogue et éviter de ressaisir les secrets.
    #
    # Les valeurs lues sont masquées à l'affichage (***) mais utilisées comme
    # défaut si l'utilisateur appuie sur Entrée sans saisir de nouvelle valeur.
    #
    def load_env_local(path : String = ".env") : Hash(String, String)
      result = {} of String => String
      return result unless File.exists?(path)

      File.each_line(path) do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#")
        if stripped.includes?("=")
          key, _, value = stripped.partition("=")
          result[key.strip] = value.strip
        end
      end

      result
    end

    # Variables par défaut si .env.example est absent (projet Marten minimal)
    private def default_env_vars : Array(EnvExampleVar)
      vars = [] of EnvExampleVar

      if marten?
        vars << EnvExampleVar.new("MARTEN_ENV",           is_marten_auto: true)
        vars << EnvExampleVar.new("MARTEN_ALLOWED_HOSTS", is_marten_auto: true)
        vars << EnvExampleVar.new("MARTEN_SOCKET",        is_marten_auto: true)
        vars << EnvExampleVar.new("SECRET_KEY",
          comment: "Clé secrète de l'application",
          is_secret: true, is_generated: true)
        PG_VARS_MARTEN.each do |k|
          vars << EnvExampleVar.new(k, is_pg: true)
        end
        vars << EnvExampleVar.new("DB_POOL_SIZE",
          default_value: "10",
          comment: "Taille du pool de connexions PostgreSQL")
      else
        vars << EnvExampleVar.new("SECRET_KEY",
          comment: "Clé secrète de l'application",
          is_secret: true, is_generated: true)
        PG_VARS_KEMAL.each do |k|
          vars << EnvExampleVar.new(k, is_pg: true)
        end
      end

      vars
    end
  end
end