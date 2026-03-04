module Aloli
  module Deploy
    module Commands
      class Status
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
            command: "status"
          )
          runner.run
        end
      end
    end
  end
end
