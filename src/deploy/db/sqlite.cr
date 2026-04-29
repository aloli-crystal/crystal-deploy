module Deploy
  module DB
    # Dialogue SQLite interactif.
    # Demande uniquement le chemin du fichier de base de données.
    # Aucune valeur par défaut — l'utilisateur saisit tout.
    class Sqlite < Base
      def run_dialog : Hash(String, String)
        log_section I18n.t("db.section")
        puts ""
        log_info I18n.t("db.sqlite_info")
        puts ""

        db_path = ask_required(I18n.t("db.sqlite_path_prompt"))

        if @config.marten?
          {"DB_PATH" => db_path}
        else
          {"DATABASE_URL" => "sqlite3://#{db_path}"}
        end
      end

      # ── Privé ──────────────────────────────────────────────────────────────

      private def ask_required(prompt : String) : String
        loop do
          value = ask("#{prompt} : ")
          return value unless value.empty?
          log_warn I18n.t("init.required_empty")
        end
      end
    end
  end
end
