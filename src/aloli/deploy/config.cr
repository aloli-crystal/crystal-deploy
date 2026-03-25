module Aloli
  module Deploy
    # Représente un environnement de déploiement (developpement, production, etc.)
    class Environment
      include YAML::Serializable

      property branch : String
      property host : String
      property user : String
      property app_url : String
      property dns_subdomain : String? = nil
      property dns_target : String? = nil

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

      # Chemin du socket Unix par défaut (convention /tmp comme PostgreSQL)
      def socket_path(app_name : String) : String
        "/tmp/.#{full_name(app_name)}.sock"
      end

      # Chemin du pidfile
      def pid_path(app_name : String) : String
        "/tmp/.#{full_name(app_name)}.pid"
      end

      # Nom du service rc.d (tirets → underscores)
      def service_rc_name(app_name : String) : String
        full_name(app_name).tr("-", "_")
      end
    end

    # Définition d'une variable d'environnement dans le dialogue init
    class EnvVar
      include YAML::Serializable

      property key : String
      property label : String
      property default_from : String? = nil
      property generate : String? = nil      # hex32 | base64_20
      property build_from_pg : Bool? = nil
      property optional : Bool? = nil
      property secret : Bool? = nil
    end

    # Configuration OVH DNS
    class OvhConfig
      include YAML::Serializable

      property dns_zone : String = "aloli.app"
      property api_url : String = "https://eu.api.ovh.com/1.0"
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
          STDERR.puts "Framework inconnu : #{s}. Valeurs acceptées : marten, kemal".colorize(:red)
          exit 1
        end
      end
    end

    # Configuration principale lue depuis config/deploy.yml
    class Config
      include YAML::Serializable

      property app_name : String
      property repo_url : String
      property crystal_main : String
      property crystal_flags : String? = nil
      property keep_releases : Int32 = 10
      property framework : String = "kemal"   # marten | kemal
      property environments : Hash(String, Environment)
      property env_vars : Array(EnvVar) = [] of EnvVar
      property ovh : OvhConfig? = nil

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

      # Retourne la zone DNS OVH (depuis la config ovh: ou valeur par défaut)
      def ovh_dns_zone : String
        ovh.try(&.dns_zone) || "aloli.app"
      end

      # Retourne l'URL de l'API OVH
      def ovh_api_url : String
        ovh.try(&.api_url) || "https://eu.api.ovh.com/1.0"
      end

      # Charge la configuration depuis un fichier YAML
      def self.load(path : String = "config/deploy.yml") : Config
        unless File.exists?(path)
          STDERR.puts "Erreur : fichier de configuration introuvable : #{path}".colorize(:red)
          STDERR.puts "Créez config/deploy.yml à partir de l'exemple fourni par le shard.".colorize(:yellow)
          exit 1
        end

        config = Config.from_yaml(File.read(path))

        # Injecter le nom de l'environnement dans chaque objet Environment
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
    end
  end
end
