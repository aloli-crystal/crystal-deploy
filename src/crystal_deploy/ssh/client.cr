module CrystalDeploy
  module SSH
    # Encapsule les opérations SSH locales (via le binaire ssh/scp système).
    # Le binaire deploy s'exécute localement et délègue les opérations au serveur
    # via SSH, exactement comme le faisait deploy.sh.
    class Client
      include Logger

      getter host : String
      getter user : String

      def initialize(@host : String, @user : String)
      end

      # Vérifie que la connexion SSH fonctionne
      def check_connection! : Nil
        log_local "Vérification de la connexion SSH vers #{@user}@#{@host}..."
        result = Process.run(
          "ssh",
          ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
           "#{@user}@#{@host}", "echo ok"],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close
        )
        unless result.success?
          log_error "Impossible de se connecter à #{@user}@#{@host} via SSH."
          log_error "Vérifiez que votre clé SSH est autorisée sur le serveur :"
          log_error "  ssh-copy-id #{@user}@#{@host}"
          exit 1
        end
        log_local "Connexion SSH établie."
      end

      # Copie un fichier local vers le serveur distant
      def upload(local_path : String, remote_path : String) : Nil
        result = Process.run(
          "scp",
          ["-q", local_path, "#{@user}@#{@host}:#{remote_path}"],
          output: Process::Redirect::Inherit,
          error: Process::Redirect::Inherit
        )
        unless result.success?
          log_error "Échec de la copie vers #{@host}:#{remote_path}"
          exit 1
        end
      end

      # Exécute une commande sur le serveur distant (TTY alloué pour l'interactivité)
      # ServerAliveInterval=30 évite le timeout SSH pendant la compilation Crystal
      def exec_remote(command : String) : Int32
        result = Process.run(
          "ssh",
          ["-t",
           "-o", "ServerAliveInterval=30",
           "-o", "ServerAliveCountMax=60",
           "#{@user}@#{@host}",
           command],
          input: STDIN,
          output: STDOUT,
          error: STDERR
        )
        result.exit_code
      end
    end
  end
end