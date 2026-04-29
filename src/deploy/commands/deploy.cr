module Deploy
  module Commands
    class Deploy
      include Logger

      def initialize(@config : Config, @env : Environment)
      end

      def run : Nil
        ssh = SSH::Client.new(@env.host, @env.user)
        ssh.check_connection!

        runner = SSH::RemoteRunner.new(
          client: ssh,
          config: @config,
          env: @env,
          command: "deploy"
        )
        runner.run
      end
    end
  end
end
