module CrystalDeploy
  # Système de traduction simple basé sur des fichiers YAML.
  #
  # Les fichiers de traduction sont **embarqués dans le binaire** à la compilation
  # via la macro `read_file`. Cela garantit que les traductions sont toujours
  # disponibles quel que soit l'emplacement du binaire sur le système.
  #
  # Détection automatique de la langue depuis la variable LANG du shell :
  #   LANG=fr_FR.UTF-8  →  "fr"  →  charge les traductions françaises
  #   LANG=en_US.UTF-8  →  "en"  →  charge les traductions anglaises
  #   LANG absent       →  fallback sur "en"
  #
  # Si la langue détectée n'est pas disponible, fallback sur "en".
  #
  # Utilisation :
  #   I18n.t("init.section_env")
  #   I18n.t("db.mode_socket")
  #   I18n.t("errors.unknown_env", name: "staging")
  #
  module I18n
    # Traductions embarquées à la compilation.
    # read_file est résolu relativement au fichier source (depuis src/crystal_deploy/).
    LOCALE_CONTENTS = {
      "fr" => {{ read_file("#{__DIR__}/../../locales/fr.yml") }},
      "en" => {{ read_file("#{__DIR__}/../../locales/en.yml") }},
      "es" => {{ read_file("#{__DIR__}/../../locales/es.yml") }},
      "de" => {{ read_file("#{__DIR__}/../../locales/de.yml") }},
      "pt" => {{ read_file("#{__DIR__}/../../locales/pt.yml") }},
      "it" => {{ read_file("#{__DIR__}/../../locales/it.yml") }},
      "nl" => {{ read_file("#{__DIR__}/../../locales/nl.yml") }},
    }

    # Cache des traductions parsées (clé : code langue, ex: "fr")
    @@translations = {} of String => Hash(String, YAML::Any)

    # Langue active (détectée une seule fois au démarrage)
    @@lang : String? = nil

    # Répertoire des locales — conservé pour la compatibilité des tests
    # (non utilisé en production : les locales sont embarquées dans LOCALE_CONTENTS)
    class_property locales_dir : String = ""

    # Retourne la langue active (détectée depuis LANG, fallback "en")
    def self.lang : String
      @@lang ||= detect_lang
    end

    # Force la langue (utile dans les tests)
    def self.lang=(value : String)
      @@lang = value
      @@translations.clear
    end

    # Traduit une clé de la forme "section.sous_cle"
    # Les interpolations sont passées en arguments nommés.
    # Exemple : I18n.t("errors.unknown_env", name: "staging")
    def self.t(translation_key : String, **args) : String
      translations = load_lang(lang)
      value = dig(translations, translation_key)

      if value.nil? && lang != "en"
        # Fallback sur l'anglais si la clé est absente dans la langue active
        en_translations = load_lang("en")
        value = dig(en_translations, translation_key)
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

      # 1. Chercher dans les locales embarquées (priorité)
      if LOCALE_CONTENTS.has_key?(code)
        parsed = YAML.parse(LOCALE_CONTENTS[code])
        @@translations[code] = flatten(parsed)
        return @@translations[code]
      end

      # 2. Chercher dans locales_dir (pour les tests avec surcharge de fichiers externes)
      unless locales_dir.empty?
        path = File.join(locales_dir, "#{code}.yml")
        if File.exists?(path)
          parsed = YAML.parse(File.read(path))
          @@translations[code] = flatten(parsed)
          return @@translations[code]
        end
      end

      # 3. Langue inconnue → hash vide (déclenchera le fallback sur "en")
      @@translations[code] = {} of String => YAML::Any
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
    private def self.dig(translations : Hash(String, YAML::Any), key : String) : String?
      val = translations[key]?
      val ? val.as_s? : nil
    end
  end
end
