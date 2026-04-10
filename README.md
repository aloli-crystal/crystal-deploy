# crystal-deploy

Shard Crystal pour le deploiement d'applications **Marten** et **Kemal** sur **FreeBSD**.

Architecture style Capistrano : `releases/`, `current/`, `shared/`.
Generation dynamique des scripts `rc.d` et `nginx.conf`.

## Installation

Ajouter dans `shard.yml` :

```yaml
dependencies:
  crystal-deploy:
    github: aloli-crystal/crystal-deploy
    branch: main

targets:
  deploy:
    main: lib/crystal-deploy/src/deploy.cr
```

```bash
shards install
shards build deploy
```

## Configuration

Creer `config/deploy.yml` a la racine du projet :

```yaml
app_name: mon-app
repo_url: git@github.com:user/mon-app.git
crystal_main: src/server.cr
keep_releases: 10
framework: marten          # marten | kemal
database: postgresql       # postgresql | mariadb | sqlite | none

# DNS automatique (optionnel)
dns:
  registrar: ovh           # ovh | gandi
  zone: example.app

# Variables d'environnement
env_vars:
  required:
    - key: SECRET_KEY
      secret: true
      generate: hex64
  # skip:
  #   - MA_VARIABLE_LOCALE

environments:
  staging:
    branch: staging
    host: staging.example.com
    user: deploy
    app_url: https://staging.mon-app.example.app

  production:
    branch: production
    host: prod.example.com
    user: deploy
    app_url: https://mon-app.example.app
```

## Commandes

```bash
bin/deploy init --staging       # Initialisation du serveur (une seule fois)
bin/deploy deploy --staging     # Deploiement d'une nouvelle release
bin/deploy deploy --production  # Deploiement en production
bin/deploy rollback --staging   # Retour a la release precedente
bin/deploy status --staging     # Version active et releases disponibles
bin/deploy generate-ci          # Generer le workflow GitHub Actions
bin/deploy dns-setup --staging  # Configurer les cles DNS (OVH / Gandi)
```

### Detection automatique de l'environnement

Sans `--<env>`, la branche git courante est utilisee pour deduire l'environnement :

```bash
git checkout staging
bin/deploy deploy               # → deploie staging automatiquement

git checkout production
bin/deploy deploy               # → deploie production automatiquement
```

La correspondance se fait via le champ `branch` de chaque environnement dans `config/deploy.yml`.

### Raccourcis par prefixe

Les noms d'environnement peuvent etre abreges :

```bash
bin/deploy deploy --stag        # → staging
bin/deploy deploy --prod        # → production
```

## Flow de deploiement

Le deploiement est optimise pour minimiser le temps d'indisponibilite. Les etapes qui utilisent `bin/marten` tournent en parallele avec la compilation du binaire applicatif :

```
clone_repo
link_shared
shards_prepare              # bin/marten disponible (~15s)
compile_start               # crystal build --release en arriere-plan (~200s)
  |-- run_migrations        #   en parallele
  |-- run_seed              #
  |-- collect_assets        #
  |-- install_crontab       #
compile_wait                # synchronisation
activate_release            # ln -sf → zero downtime
init_rcd
generate_env_exports
generate_wrapper
start_service
reload_nginx
cleanup_releases
```

## Crontab automatique

Si le projet contient `config/cron/crontab`, il est installe automatiquement lors du deploiement.

### Pour les projets Marten

Ajouter une commande CLI `install_cron` dans le projet :

```crystal
class InstallCron < Marten::CLI::Command
  command_name :install_cron
  help "Installe le crontab depuis config/cron/crontab."

  def run
    # ... voir la documentation Marten
  end
end
```

crystal-deploy appellera `./bin/marten install_cron` avec les variables d'environnement `APP_HOME`, `APP_FULL_NAME` et `MARTEN_ENV`.

### Variables disponibles dans le template crontab

| Variable | Description | Exemple |
|---|---|---|
| `{{APP_HOME}}` | Repertoire home de l'application | `/home/mon-app--staging` |
| `{{APP_FULL_NAME}}` | Nom complet app--env | `mon-app--staging` |
| `{{MARTEN_ENV}}` | Environnement Marten | `staging` |

### Exemple `config/cron/crontab`

```crontab
# Recap quotidien a 7h
0 7 * * * cd {{APP_HOME}}/current && MARTEN_ENV={{MARTEN_ENV}} ./bin/{{APP_FULL_NAME}} recap_quotidien >> {{APP_HOME}}/shared/log/cron.log 2>&1
```

La commande est **idempotente** : si le crontab est deja identique, rien n'est reinstalle.

### Pour les projets Kemal

Le fallback `sed` est utilise : les variables `{{...}}` sont remplacees et le crontab est installe via `crontab(1)`.

## Structure sur le serveur

```
/home/mon-app--staging/
  current -> releases/20260410_123456
  releases/
    20260410_123456/
    20260409_100000/
  shared/
    .env
    env_exports.sh
    log/
    repo.git/                 # depot bare (fetch incremental)
```

## Variables d'environnement

### Gerees automatiquement (skip par defaut)

Ces variables sont injectees par crystal-deploy et ne sont jamais demandees lors du `init` :

- `MARTEN_ENV`, `MARTEN_ALLOWED_HOSTS`, `MARTEN_SOCKET`
- `APP_HOST`, `APP_PORT`, `PORT`
- `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_NAME_TEST`
- `DATABASE_URL`

### Variables personnalisees

Declarees dans la section `env_vars.required` de `config/deploy.yml` :

```yaml
env_vars:
  required:
    - key: SECRET_KEY
      secret: true        # masque la saisie
      generate: hex64     # auto-genere si vide (hex32 | hex64 | password)
    - key: STRIPE_SECRET_KEY
      secret: true
```

## DNS automatique

Registrars supportes : **OVH** et **Gandi**.

```bash
bin/deploy dns-setup --staging   # Configure les cles API du registrar
```

Les enregistrements CNAME sont crees automatiquement lors du `init` si la configuration DNS est presente.

### Champs DNS optionnels par environnement

```yaml
environments:
  staging:
    # ...
    dns_subdomain: staging.mon-app    # sous-domaine explicite (defaut : premier label de app_url)
    dns_target: serveur.example.com.  # cible CNAME (defaut : host avec point final)
```

## CI/CD

```bash
bin/deploy generate-ci
```

Genere `.github/workflows/deploy.yml` avec :
- **Job test** : PostgreSQL, Crystal, compilation + specs
- **Job deploy** : deploiement automatique sur push (staging / production)
- Notifications GitHub Issues en cas d'echec

## Frameworks supportes

| | Marten | Kemal |
|---|---|---|
| Migrations | `bin/marten migrate` | `schema_pg.sql` |
| Seed | `bin/marten seed` | - |
| Assets | `bin/marten collectassets` | - |
| Crontab | `bin/marten install_cron` | `sed` + `crontab` |
| Service | rc.d + socket Unix | rc.d + TCP |

## Licence

MIT
