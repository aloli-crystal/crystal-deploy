module Aloli
  module Deploy
    module Generators
      # Génère le fichier .github/workflows/deploy.yml
      class GitHubWorkflow
        def initialize(@config : Config)
        end

        def generate : String
          # Détecter les noms d'environnement (ex: developpement, production)
          dev_env = @config.environments.keys.find { |k| k.starts_with?("dev") } || "developpement"
          prod_env = @config.environments.keys.find { |k| k.starts_with?("prod") } || "production"

          <<-YAML
          # Fichier généré par aloli-cr-deploy. Ne pas modifier manuellement.
          name: CI/CD - Déploiement continu

          on:
            push:
              branches:
                - #{dev_env}
                - #{prod_env}

          jobs:
            test:
              runs-on: ubuntu-latest
              container:
                image: crystallang/crystal:latest-alpine
              steps:
                - name: Checkout
                  uses: actions/checkout@v4
                - name: Installation des dépendances
                  run: shards install
                - name: Lancement des tests
                  run: | # Le service DB doit être démarré dans le workflow de test
                    apk add --no-cache postgresql-client
                    # Assurez-vous d'avoir un service postgres dans votre workflow
                    # ou utilisez une base de données de test externe.
                    # export DATABASE_URL=...
                    crystal spec

            deploy:
              needs: test
              runs-on: ubuntu-latest
              if: github.ref == 'refs/heads/#{dev_env}' || github.ref == 'refs/heads/#{prod_env}'

              steps:
                - name: Checkout
                  uses: actions/checkout@v4

                - name: Installation de Crystal
                  uses: crystal-lang/install-crystal@v1

                - name: Installation des dépendances
                  run: shards install

                - name: Compilation du binaire de déploiement
                  run: crystal build src/deploy.cr -o bin/deploy

                - name: Configuration de SSH
                  uses: webfactory/ssh-agent@v0.9.0
                  with:
                    ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

                - name: Ajout du serveur aux known_hosts
                  run: ssh-keyscan -H ${{ secrets.SSH_HOST }} >> ~/.ssh/known_hosts

                - name: Déploiement sur Staging
                  if: github.ref == 'refs/heads/#{dev_env}'
                  run: bin/deploy --#{dev_env} deploy

                - name: Déploiement sur Production
                  if: github.ref == 'refs/heads/#{prod_env}'
                  run: bin/deploy --#{prod_env} deploy
          YAML
        end
      end
    end
  end
end
