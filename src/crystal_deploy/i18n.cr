module CrystalDeploy
  # Système de traduction simple basé sur des fichiers YAML.
  #
  # Détection automatique de la langue depuis la variable LANG du shell :
  #   LANG=fr_FR.UTF-8  →  "fr"  →  charge locales/fr.yml
  #   LANG=en_US.UTF-8  →  "en"  →  charge locales/en.yml
  #   LANG absent       →  fallback sur "en"
  #
  # Si le fichier de la langue détectée est absent, fallback sur "en".
  #
  # Utilisation :
  #   I18n.t("init.section_env")
  #   I18n.t("db.mode_socket")
  #   I18n.t("errors.unknown_env", name: "staging")
  #
  module I18n
    # Chemin vers le répertoire des fichiers de traduction.
    # Peut être surchargé dans les tests.
    class_property locales_dir : String = File.join(
      File.dirname(File.dirname(File.dirname(__DIR__))),
      "locales"
    )

    # Cache des traductions chargées (clé : code langue, ex: "fr")
    @@translations = {} of String => Hash(String, YAML::Any)

    # Langue active (détectée une seule fois au démarrage)
    @@lang : String? = nil

    # Retourne la langue active (détectée depuis LANG, fallback "en")
    def self.lang : String
      @@lang ||= detect_lang
    end

    # Force la langue (utile dans les tests)
    def self.lang=(value : String)
      @@lang = value
    end

    # Traduit une clé de la forme "section.sous_cle"
    # Les interpolations sont passées en arguments nommés.
    # Exemple : I18n.t("errors.unknown_env", name: "staging")
    def self.t(translation_key : String, **args) : String
      translations = load_lang(lang)
      value = dig(translations, translation_key.split("."))

      if value.nil?
        # Fallback sur l'anglais si la clé est absente dans la langue active
        if lang != "en"
          en_translations = load_lang("en")
          value = dig(en_translations, translation_key.split("."))
        end
      end

      result = value || translation_key  # Si toujours absent, retourner la clé brute

      # Interpolation des arguments nommés (%{name} → valeur)
      args.each do |k, v|
        result = result.gsub("%{#{k}}", v.to_s)
      end

      result
    end

    # Réinitialise le cache (utile dans les tests)
    def self.reset
      @@translations.clear
      @@lang = nil
    end

    # ── Privé ────────────────────────────────────────────────────────────────

    private def self.detect_lang : String
      raw = ENV.fetch("LANG", "en")
      # "fr_FR.UTF-8" → "fr", "C" → "en", "" → "en"
      code = raw.split(/[_.]/).first.downcase
      code.empty? || code == "c" || code == "posix" ? "en" : code
    end

    private def self.load_lang(code : String) : Hash(String, YAML::Any)
      return @@translations[code] if @@translations.has_key?(code)

      path = File.join(locales_dir, "#{code}.yml")
      if File.exists?(path)
        parsed = YAML.parse(File.read(path))
        @@translations[code] = flatten(parsed)
      else
        @@translations[code] = {} of String => YAML::Any
      end

      @@translations[code]
    end

    # Aplatit un YAML::Any imbriqué en Hash(String, YAML::Any) avec clés "section.cle"
    private def self.flatten(node : YAML::Any, prefix : String = "") : Hash(String, YAML::Any)
      result = {} of String => YAML::Any

      if node.as_h?
        node.as_h.each do |k, v|
          full_key = prefix.empty? ? k.to_s : "#{prefix}.#{k}"
          if v.as_h?
            flatten(v, full_key).each { |fk, fv| result[fk] = fv }
          else
            result[full_key] = v
          end
        end
      end

      result
    end

    # Recherche une clé dans le hash aplati
    private def self.dig(translations : Hash(String, YAML::Any), parts : Array(String)) : String?
      key = parts.join(".")
      val = translations[key]?
      val ? val.as_s? : nil
    end
  end
end
