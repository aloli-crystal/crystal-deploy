module Deploy
  module Commands
    class GenerateCI
      include Logger

      def initialize(@config : Config)
      end

      def run : Nil
        log_local "Génération du workflow GitHub Actions..."

        workflow_content = Generators::GitHubWorkflow.new(@config).generate
        workflow_dir = ".github/workflows"
        workflow_path = File.join(workflow_dir, "deploy.yml")

        Dir.mkdir_p(workflow_dir)
        File.write(workflow_path, workflow_content)

        log_info "Workflow généré : #{workflow_path}"
        log_warn "N'oubliez pas de configurer les secrets suivants dans votre dépôt GitHub :"
        log_warn "  - SSH_PRIVATE_KEY : Clé SSH privée pour se connecter au serveur de déploiement."
        log_warn "  - SSH_HOST : L'adresse du serveur de déploiement (ex: deploy.example.com)."
      end
    end
  end
end
