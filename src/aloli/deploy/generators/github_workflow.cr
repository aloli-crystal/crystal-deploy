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
          # Pour regénérer : bin/deploy generate-ci
          name: CI/CD — Déploiement continu

          on:
            push:
              branches:
                - #{dev_env}
                - #{prod_env}

          jobs:
            # ─────────────────────────────────────────────────────────────────
            # Job 1 : Tests
            # ─────────────────────────────────────────────────────────────────
            test:
              runs-on: ubuntu-latest

              services:
                postgres:
                  image: postgres:16-alpine
                  env:
                    POSTGRES_USER: runner
                    POSTGRES_PASSWORD: ""
                    POSTGRES_HOST_AUTH_METHOD: trust
                  ports:
                    - 5432:5432
                  options: >-
                    --health-cmd pg_isready
                    --health-interval 10s
                    --health-timeout 5s
                    --health-retries 5

              steps:
                - name: Checkout
                  uses: actions/checkout@v4

                - name: Installation de Crystal
                  uses: crystal-lang/install-crystal@v1

                - name: Installation des dépendances
                  run: shards install

                - name: Lancement des tests
                  env:
                    DATABASE_URL: postgresql://runner@localhost:5432/#{@config.app_name.gsub("-", "_")}__test
                  run: |
                    psql -U runner -h localhost -c "CREATE DATABASE #{@config.app_name.gsub("-", "_")}__test;"
                    psql -U runner -h localhost #{@config.app_name.gsub("-", "_")}__test -f db/schema_pg.sql
                    crystal spec

            # ─────────────────────────────────────────────────────────────────
            # Job 2 : Déploiement (uniquement si les tests passent)
            # ─────────────────────────────────────────────────────────────────
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
                  run: crystal build lib/aloli-cr-deploy/src/deploy.cr --release -o bin/deploy

                - name: Configuration de SSH
                  uses: webfactory/ssh-agent@v0.9.0
                  with:
                    ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

                - name: Ajout du serveur aux known_hosts
                  run: ssh-keyscan -H ${{ secrets.SSH_HOST }} >> ~/.ssh/known_hosts

                - name: Déploiement sur Staging
                  if: github.ref == 'refs/heads/#{dev_env}'
                  run: bin/deploy deploy --#{dev_env}

                - name: Déploiement sur Production
                  if: github.ref == 'refs/heads/#{prod_env}'
                  run: bin/deploy deploy --#{prod_env}
          YAML
        end
      end
    end
  end
end
