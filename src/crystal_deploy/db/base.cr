module CrystalDeploy
  module DB
    # Interface abstraite pour le dialogue de base de données.
    # Chaque adaptateur implémente cette classe.
    #
    # Pour ajouter un adaptateur :
    #   1. Créer db/mon_adaptateur.cr héritant de DB::Base
    #   2. Implémenter run_dialog
    #   3. L'enregistrer dans DB::Factory
    abstract class Base
      include Logger

      def initialize(@config : Config, @env : Environment)
      end

      # Lance le dialogue interactif et retourne les variables d'environnement
      # construites sous forme de Hash.
      #
      # Pour PostgreSQL (Marten) :
      #   {"DB_HOST" => "...", "DB_PORT" => "...", "DB_USER" => "...",
      #    "DB_PASSWORD" => "...", "DB_NAME" => "..."}
      #
      # Pour PostgreSQL (Kemal) :
      #   {"DATABASE_URL" => "postgresql://..."}
      #
      # Pour None :
      #   {} (hash vide)
      abstract def run_dialog : Hash(String, String)
    end

    # Adaptateur "none" : pas de base de données
    class None < Base
      def run_dialog : Hash(String, String)
        {} of String => String
      end
    end

    # Factory : instancie le bon adaptateur selon la configuration
    module Factory
      def self.for(database : String, config : Config, env : Environment) : Base
        case database.downcase
        when "postgresql", "postgres", "pg"
          Postgresql.new(config, env)
        when "sqlite"
          Sqlite.new(config, env)
        when "mariadb", "mysql"
          Mariadb.new(config, env)
        when "none", ""
          None.new(config, env)
        else
          STDERR.puts I18n.t("errors.unknown_database", name: database).colorize(:red)
          STDERR.puts "Valeurs acceptées : postgresql, mariadb, mysql, sqlite, none".colorize(:yellow)
          exit 1
        end
      end
    end
  end
end
