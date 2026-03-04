module Aloli
  module Deploy
    module Logger
      def log_info(msg : String)
        puts "[INFO]  #{msg}".colorize(:green)
      end

      def log_warn(msg : String)
        puts "[WARN]  #{msg}".colorize(:yellow)
      end

      def log_error(msg : String)
        STDERR.puts "[ERROR] #{msg}".colorize(:red)
      end

      def log_section(title : String)
        puts ""
        puts "=== #{title} ===".colorize(:green).bold
      end

      def log_local(msg : String)
        puts "[LOCAL] #{msg}".colorize(:cyan)
      end

      def ask(prompt : String) : String
        print prompt.colorize.bold
        STDIN.gets.to_s.strip
      end

      def confirm?(prompt : String) : Bool
        answer = ask("#{prompt} [O/n] : ")
        !answer.downcase.starts_with?("n")
      end
    end
  end
end
