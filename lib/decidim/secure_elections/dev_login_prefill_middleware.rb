# frozen_string_literal: true

module Decidim
  module SecureElections
    # Injects a small `<script>` on the Devise sign-in page that pre-fills
    # the email + password inputs with the default seeded admin credentials.
    # Mirrors `try.decidim.org`, so an operator can drop into the deploy
    # without hunting for the password. Dev only — the engine initializer
    # only mounts this middleware when `Rails.env.development?`.
    class DevLoginPrefillMiddleware
      SIGN_IN_PATH_FRAGMENT = "/users/sign_in"

      SNIPPET = <<~HTML.strip.freeze
        <script>(function(){
          var setValue=function(sel,val){
            document.querySelectorAll(sel).forEach(function(el){
              if(!el.value) el.value=val;
            });
          };
          setValue('input[name="user[email]"]','admin@example.org');
          setValue('input[name="user[password]"]','decidim123456789');
        })();</script>
      HTML

      def initialize(app)
        @app = app
      end

      def call(env)
        status, headers, response = @app.call(env)
        return [status, headers, response] unless inject?(env, headers)

        body = +""
        response.each { |chunk| body << chunk.to_s }
        response.close if response.respond_to?(:close)

        body.sub!("</body>", "#{SNIPPET}</body>") if body.include?("</body>")
        headers["Content-Length"] = body.bytesize.to_s if headers.key?("Content-Length")
        headers["content-length"] = body.bytesize.to_s if headers.key?("content-length")

        [status, headers, [body]]
      end

      private

      def inject?(env, headers)
        return false unless env["PATH_INFO"].to_s.include?(SIGN_IN_PATH_FRAGMENT)

        content_type = headers["Content-Type"] || headers["content-type"] || ""
        content_type.include?("text/html")
      end
    end
  end
end
