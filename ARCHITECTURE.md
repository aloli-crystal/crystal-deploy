# Architecture crystal-deploy — Spécification

## Objectif

Shard Crystal en ligne de commande pour déployer des applications Marten ou Kemal
sur un serveur FreeBSD. Simple, testable, extensible.

---

## Principes fondamentaux

1. **Pas de valeur par défaut dans le dialogue** — l'utilisateur saisit tout explicitement.
2. **Le `.env` local n'est jamais lu pour le déploiement** — il appartient au développeur.
3. **`config/deploy.yml` est la seule source de vérité** pour l'infrastructure.
4. **Multi-langue** — les messages sont dans des fichiers YAML, fallback sur l'anglais.
5. **Extensible** — ajouter un registrar DNS ou un moteur de base de données sans toucher au cœur.

---

## Structure des fichiers

```
src/
  deploy.cr                        # point d'entrée
  crystal_deploy/
    cli.cr                         # parsing des arguments
    config.cr                      # lecture de config/deploy.yml
    i18n.cr                        # traductions (LANG → fichier YAML)
    logger.cr                      # affichage coloré + ask/confirm
    commands/
      init.cr                      # dialogue interactif + envoi SSH
      deploy.cr
      rollback.cr
      status.cr
      generate_ci.cr
    dns/
      base.cr                      # interface DNS (abstract)
      ovh.cr                       # implémentation OVH
    db/
      base.cr                      # interface DB (abstract)
      postgresql.cr                # dialogue PostgreSQL (socket ou TCP)
    generators/
      nginx.cr
      rcd.cr
      github_workflow.cr

locales/
  fr.yml
  en.yml

examples/
  marten/
    config/deploy.yml
    .env.example
  kemal/
    config/deploy.yml
    .env.example

spec/
  spec_helper.cr
  crystal_deploy/
    config_spec.cr
    i18n_spec.cr
    init_spec.cr
    dns/ovh_spec.cr
    db/postgresql_spec.cr
    generators_spec.cr
```

---

## `config/deploy.yml` — Format cible

```yaml
app_name: mon-app
repo_url: git@github.com:user/mon-app.git
crystal_main: src/server.cr
keep_releases: 10
framework: marten          # marten | kemal

# Adaptateur de base de données (défaut: postgresql)
database: postgresql       # postgresql | sqlite | none

# Registrar DNS (optionnel — si absent, pas de gestion DNS)
dns:
  registrar: ovh           # ovh | (futur: gandi, cloudflare, etc.)
  zone: example.app

environments:
  developpement:
    branch: developpement
    host: dev.example.com
    user: deploy
    app_url: https://dev.mon-app.example.app
  production:
    branch: production
    host: prod.example.com
    user: deploy
    app_url: https://mon-app.example.app

# Variables demandées lors du `init`
# Ordre d'affichage respecté.
# Les variables DB sont gérées par le dialogue `database`.
# Les variables MARTEN_* sont injectées automatiquement.
env_vars:
  - key: SECRET_KEY
    required: true
    secret: true
    generate: hex64        # généré automatiquement si laissé vide

  - key: SMTP_HOST
    required: false        # optionnel : sauté si vide

  - key: SMTP_PORT
    required: false

  - key: SMTP_USER
    required: false

  - key: SMTP_PASSWORD
    required: false
    secret: true

  - key: EMAIL_FROM
    required: false

  - key: STRIPE_SECRET_KEY
    required: false
    secret: true

  - key: STRIPE_PUBLISHABLE_KEY
    required: false

  - key: STRIPE_WEBHOOK_SECRET
    required: false
    secret: true
```

**Règles :**
- `required: true` → le dialogue insiste jusqu'à obtenir une valeur (sauf si `generate` est défini)
- `required: false` → optionnel, une entrée vide est acceptée
- `secret: true` → la valeur est masquée à l'affichage (`***`)
- `generate: hex64` → génère automatiquement si vide (`hex32`, `hex64`, `password`)
- Les variables DB (`DB_HOST`, `DB_PORT`, etc.) sont **toujours** gérées par le dialogue `database`
- Les variables Marten (`MARTEN_ENV`, `MARTEN_ALLOWED_HOSTS`, `MARTEN_SOCKET`) sont **toujours** injectées automatiquement

---

## Système de traduction (I18n)

### Fichier `locales/fr.yml`

```yaml
init:
  section_env: "Configuration de l'environnement (.env)"
  intro: "Ce dialogue va construire le fichier .env pour [%{env}]."
  press_enter: "Appuyez sur Entrée pour passer les champs optionnels."
  generated: "%{key} généré automatiquement."
  summary: "Récapitulatif :"
  confirm_send: "Confirmer et envoyer sur le serveur ?"
  required_empty: "Ce champ est obligatoire."

db:
  section: "Base de données"
  mode_prompt: "Mode de connexion :"
  mode_socket: "Socket Unix (recommandé si PostgreSQL est sur le même serveur)"
  mode_tcp: "TCP (hôte distant)"
  user_prompt: "Utilisateur PostgreSQL"
  password_prompt: "Mot de passe PostgreSQL (généré si vide)"
  db_prompt: "Nom de la base de données"
  socket_dir_prompt: "Répertoire du socket PostgreSQL"
  host_prompt: "Hôte PostgreSQL"

dns:
  section: "Configuration DNS"
  keys_found: "Clés %{registrar} trouvées."
  confirm_cname: "Créer/vérifier le CNAME %{sub}.%{zone} → %{target} ?"
  configure_now: "Configurer l'API %{registrar} maintenant ?"
  keys_ready: "Avez-vous vos trois clés prêtes ?"
  saved: "Clés sauvegardées dans %{path} (permissions 600)."
  check_gitignore: "Vérifiez que %{path} est dans votre .gitignore !"

errors:
  unknown_env: "Environnement inconnu : %{name}"
  available_envs: "Environnements disponibles : %{list}"
  config_missing: "Fichier de configuration introuvable : %{path}"
```

### Détection de la langue

```crystal
# i18n.cr
lang = ENV.fetch("LANG", "en")[0, 2].downcase  # "fr_FR.UTF-8" → "fr"
# Cherche locales/{lang}.yml, fallback sur locales/en.yml
```

### Utilisation dans le code

```crystal
I18n.t("init.section_env")
I18n.t("init.generated", key: "SECRET_KEY")
```

---

## Interface DNS (extensible)

```crystal
# dns/base.cr
abstract class CrystalDeploy::DNS::Base
  abstract def create_cname(subdomain : String, target : String, zone : String) : Nil
  abstract def load_credentials : Nil
  abstract def credentials_present? : Bool
  abstract def help_generate_keys(zone : String) : Nil
end
```

Chaque registrar implémente cette interface. Le `config/deploy.yml` indique `registrar: ovh`.
Pour ajouter Gandi : créer `dns/gandi.cr` et l'enregistrer dans une factory.

---

## Interface DB (extensible)

```crystal
# db/base.cr
abstract class CrystalDeploy::DB::Base
  # Retourne un Hash avec les variables d'environnement construites
  abstract def run_dialog : Hash(String, String)
end
```

Le champ `database: postgresql` dans `deploy.yml` détermine quelle classe instancier.

---

## Variables automatiques selon le framework

| Variable | Marten | Kemal |
|---|---|---|
| `MARTEN_ENV` | injectée | — |
| `MARTEN_ALLOWED_HOSTS` | injectée | — |
| `MARTEN_SOCKET` | injectée | — |
| `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` | dialogue DB | — |
| `DATABASE_URL` | — | dialogue DB |

---

## Ce qui est conservé tel quel

- `generators/nginx.cr` — fonctionnel, testé
- `generators/rcd.cr` — fonctionnel, testé
- `generators/github_workflow.cr` — fonctionnel
- `ssh/client.cr`, `ssh/remote_runner.cr`, `ssh/remote_script.cr` — fonctionnels
- `commands/deploy.cr`, `rollback.cr`, `status.cr` — stubs à compléter

## Ce qui est refactorisé

- `config.cr` — ajout `database`, `dns`, `env_vars` avec types stricts
- `commands/init.cr` — simplifié, délègue à `DB::Base` et `DNS::Base`
- `logger.cr` — intègre `I18n.t()` pour les messages
- `commands/ovh_setup.cr` — migré dans `dns/ovh.cr`

## Ce qui est supprimé

- `load_env_example` dans `config.cr` — remplacé par `env_vars:` dans `deploy.yml`
- `EnvExampleVar` struct — remplacée par `EnvVarDef` (lue depuis YAML)
- `MARTEN_AUTO_VARS`, `TEST_ONLY_VARS`, `SHELL_COMMAND_PREFIXES` — plus nécessaires
- `load_env_local` — supprimée du dialogue init (conservée uniquement pour les clés OVH)
