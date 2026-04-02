module CrystalDeploy
  # Parse un fichier .env et génère des exports shell correctement échappés.
  # Tout le parsing est fait en Crystal — aucun parsing shell des valeurs.
  module EnvParser
    # Parse le contenu d'un .env et retourne les paires clé/valeur.
    def self.parse(content : String) : Array({String, String})
      result = [] of {String, String}
      content.each_line do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        idx = line.index('=')
        next unless idx
        key = line[0...idx]
        value = line[idx + 1..]
        # Retirer les guillemets englobants éventuels
        if (value.starts_with?('"') && value.ends_with?('"')) ||
           (value.starts_with?("'") && value.ends_with?("'"))
          value = value[1...-1]
        end
        result << {key, value}
      end
      result
    end

    # Génère un script shell avec des exports correctement échappés.
    # Le fichier produit peut être sourcé ou copié dans un wrapper
    # sans aucun risque lié aux caractères spéciaux.
    def self.generate_exports(content : String) : String
      lines = [] of String
      lines << "# Fichier généré par crystal-deploy — ne pas modifier manuellement."
      lines << "# Source : shared/.env — régénéré à chaque déploiement."
      parse(content).each do |key, value|
        # Échapper les caractères spéciaux pour le double-quoting shell
        escaped = value.gsub('\\', "\\\\")
                       .gsub('"', "\\\"")
                       .gsub('$', "\\$")
                       .gsub('`', "\\`")
        lines << %(export #{key}="#{escaped}")
      end
      lines.join("\n") + "\n"
    end
  end
end
