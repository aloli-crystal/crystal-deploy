module Aloli
  module Deploy
    module Generators
      # Génère le fichier nginx.conf pour un environnement donné.
      # La génération effective sur le serveur est faite par le script distant (remote_script.cr).
      # Ce générateur est utilisé pour les tests et la prévisualisation locale.
      class Nginx
        def initialize(@config : Config, @env : Environment)
        end

        def full_name : String
          @env.full_name(@config.app_name)
        end

        def rc_name : String
          @env.service_rc_name(@config.app_name)
        end

        def app_home : String
          @env.app_home(@config.app_name)
        end

        def socket_path : String
          @env.socket_path(@config.app_name)
        end

        def server_name : String
          url = @env.app_url
          url = url.lchop("https://")
          url = url.lchop("http://")
          url
        end

        # Génère le contenu du nginx.conf
        def generate : String
          <<-NGINX
          # Configuration NGINX — #{full_name}
          # Généré par aloli-cr-deploy

          upstream #{rc_name} {
              server unix:#{socket_path};
          }

          server {
              listen 80;
              server_name #{server_name};

              access_log /var/log/nginx/#{full_name}.access.log;
              error_log  /var/log/nginx/#{full_name}.error.log;

              location / {
                  proxy_pass         http://#{rc_name};
                  proxy_set_header   Host              $host;
                  proxy_set_header   X-Real-IP         $remote_addr;
                  proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
                  proxy_set_header   X-Forwarded-Proto $scheme;
                  proxy_connect_timeout 60s;
                  proxy_send_timeout    60s;
                  proxy_read_timeout    60s;
                  client_max_body_size  2M;
              }

              location /css/    { alias #{app_home}/current/public/css/;    expires 30d; add_header Cache-Control "public, immutable"; }
              location /js/     { alias #{app_home}/current/public/js/;     expires 30d; add_header Cache-Control "public, immutable"; }
              location /vendor/ { alias #{app_home}/current/public/vendor/; expires 30d; add_header Cache-Control "public, immutable"; }
          }

          # Bloc HTTPS — activer après obtention du certificat SSL
          # server {
          #     listen 443 ssl http2;
          #     server_name #{server_name};
          #     ssl_certificate     /usr/local/etc/letsencrypt/live/#{server_name}/fullchain.pem;
          #     ssl_certificate_key /usr/local/etc/letsencrypt/live/#{server_name}/privkey.pem;
          #     ssl_protocols TLSv1.2 TLSv1.3;
          #     ssl_ciphers HIGH:!aNULL:!MD5;
          #
          #     location / {
          #         proxy_pass       http://#{rc_name};
          #         proxy_set_header Host              $host;
          #         proxy_set_header X-Real-IP         $remote_addr;
          #         proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
          #         proxy_set_header X-Forwarded-Proto $scheme;
          #     }
          # }
          NGINX
        end
      end
    end
  end
end
