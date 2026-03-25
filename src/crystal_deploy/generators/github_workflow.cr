module CrystalDeploy
  module Generators
    # Génère le fichier .github/workflows/deploy.yml
    #
    # Différences selon le framework :
    #   - marten : tests avec DB_* + MARTEN_ENV=test + marten migrate, pas de schema_pg.sql
    #   - kemal  : tests avec DATABASE_URL + schema_pg.sql statique
    class GitHubWorkflow
      def initialize(@config : Config)
      end

      def generate : String
        # Détecter les noms d'environnement
        # Priorité : préfixe "preprod" ou "pre" pour la préprod, "prod" pour la prod
        preprod_env = @config.environments.keys.find { |k|
          k.starts_with?("preprod") || k.starts_with?("pre") || k.starts_with?("dev")
        } || "preproduction"
        prod_env = @config.environments.keys.find { |k| k.starts_with?("prod") } || "production"

        preprod_host = @config.environments[preprod_env]?.try(&.host) || "deploy.example.com"
        prod_host    = @config.environments[prod_env]?.try(&.host)    || "prod.example.com"

        app_db = @config.app_name.gsub("-", "_")

        if @config.marten?
          test_steps = marten_test_steps(app_db)
        else
          test_steps = kemal_test_steps(app_db)
        end

        <<-YAML
        # Fichier généré par crystal-deploy. Ne pas modifier manuellement.
        # Pour regénérer : bin/deploy generate-ci
        # Framework : #{@config.framework}
        name: CI/CD — Déploiement continu

        on:
          push:
            branches:
              - #{preprod_env}
              - #{prod_env}

        # Annule les runs en attente sur la même branche pour éviter les
        # déploiements en file d'attente après des pushes rapides successifs.
        concurrency:
          group: deploy-${{ github.ref }}
          cancel-in-waiting: true

        jobs:
          # ─────────────────────────────────────────────────────────────────
          # Job 1 : Tests
          # ─────────────────────────────────────────────────────────────────
          test:
            name: Tests Crystal
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

        #{test_steps}

              - name: Notification d'échec des tests
                if: failure()
                uses: actions/github-script@v7
                with:
                  script: |
                    github.rest.issues.create({
                      owner: context.repo.owner,
                      repo: context.repo.repo,
                      title: `[CI] Échec des tests — ${context.ref.replace('refs/heads/', '')} @ ${context.sha.substring(0, 7)}`,
                      body: `Les tests ont échoué lors du push sur \\`${context.ref.replace('refs/heads/', '')}\\`.\\n\\n` +
                            `**Commit** : ${context.sha}\\n` +
                            `**Auteur** : ${context.actor}\\n` +
                            `**Workflow** : ${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`,
                      labels: ['bug', 'ci']
                    })

          # ─────────────────────────────────────────────────────────────────
          # Job 2 : Déploiement (uniquement si les tests passent)
          # ─────────────────────────────────────────────────────────────────
          deploy:
            name: Déploiement
            needs: test
            runs-on: ubuntu-latest
            if: github.ref == 'refs/heads/#{preprod_env}' || github.ref == 'refs/heads/#{prod_env}'

            steps:
              - name: Checkout
                uses: actions/checkout@v4

              - name: Installation de Crystal
                uses: crystal-lang/install-crystal@v1

              - name: Installation des dépendances
                run: shards install

              - name: Compilation du binaire de déploiement
                run: crystal build lib/crystal-deploy/src/deploy.cr --release -o bin/deploy

              - name: Configuration de SSH
                uses: webfactory/ssh-agent@v0.9.0
                with:
                  ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

              # Pré-production : hôte #{preprod_host}
              - name: Ajout de l'hôte pré-production aux known_hosts
                if: github.ref == 'refs/heads/#{preprod_env}'
                run: ssh-keyscan -H #{preprod_host} >> ~/.ssh/known_hosts

              # Production : hôte #{prod_host}
              - name: Ajout de l'hôte production aux known_hosts
                if: github.ref == 'refs/heads/#{prod_env}'
                run: ssh-keyscan -H #{prod_host} >> ~/.ssh/known_hosts

              - name: Déploiement sur Pré-production (#{preprod_host})
                if: github.ref == 'refs/heads/#{preprod_env}'
                run: bin/deploy deploy --#{preprod_env}

              - name: Déploiement sur Production (#{prod_host})
                if: github.ref == 'refs/heads/#{prod_env}'
                run: bin/deploy deploy --#{prod_env}

              - name: Notification d'échec du déploiement
                if: failure()
                uses: actions/github-script@v7
                with:
                  script: |
                    const env = context.ref.replace('refs/heads/', '');
                    github.rest.issues.create({
                      owner: context.repo.owner,
                      repo: context.repo.repo,
                      title: `[DEPLOY] Échec du déploiement — ${env} @ ${context.sha.substring(0, 7)}`,
                      body: `Le déploiement a échoué sur l'environnement \\`${env}\\`.\\n\\n` +
                            `**Commit** : ${context.sha}\\n` +
                            `**Auteur** : ${context.actor}\\n` +
                            `**Workflow** : ${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}\\n\\n` +
                            `Vérifiez les logs de compilation sur le serveur :\\n` +
                            `\\`sudo tail -f /home/${context.repo.repo}--${env}/shared/log/${context.repo.repo}--${env}.log\\``,
                      labels: ['bug', 'deploy']
                    })
        YAML
      end

      private def marten_test_steps(app_db : String) : String
        <<-STEPS
              - name: Lancement des tests (Marten)
                env:
                  MARTEN_ENV: test
                  SECRET_KEY: ci_test_secret_key_not_used_in_production
                  DB_HOST: localhost
                  DB_PORT: "5432"
                  DB_USER: runner
                  DB_PASSWORD: ""
                  DB_NAME: #{app_db}_test
                  DB_NAME_TEST: #{app_db}_test
                run: |
                  psql -U runner -h localhost -c "CREATE DATABASE #{app_db}_test;"
                  crystal build src/server.cr --release -o bin/#{app_db}
                  MARTEN_ENV=test ./bin/#{app_db} migrate
                  crystal spec
        STEPS
      end

      private def kemal_test_steps(app_db : String) : String
        <<-STEPS
              - name: Lancement des tests (Kemal)
                env:
                  DATABASE_URL: postgresql://runner@localhost:5432/#{app_db}__test
                run: |
                  psql -U runner -h localhost -c "CREATE DATABASE #{app_db}__test;"
                  psql -U runner -h localhost #{app_db}__test -f db/schema_pg.sql
                  crystal spec
        STEPS
      end
    end
  end
end