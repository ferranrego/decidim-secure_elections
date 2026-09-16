# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # Second-factor choice for a `:vocdoni_secure` election.
        #
        # Two independent booleans — SMS and Email — that map onto the
        # Vocdoni SaaS `twoFaFields` array (`"phone"` and `"email"`
        # respectively). All four combinations are valid:
        #
        #   [] []  → no OTP (weakest, only CSP identity)
        #   [x] [] → SMS OTP only
        #   [] [x] → Email OTP only
        #   [x] [x] → voter picks at auth time (SaaS treats twoFaFields as OR)
        #
        # Persisted through {Admin::UpdateElectionSecurity} into
        # `election.census_settings["twofa_fields"]`, which the publish job
        # reads verbatim when building the SaaS payload.
        class SecurityForm < Decidim::Form
          mimic :security

          attribute :sms, Boolean, default: false
          attribute :email, Boolean, default: false

          # Reconstructs a form from the value persisted by a previous save.
          # An election that has never visited the Security tab has no
          # `twofa_fields` key and both checkboxes default to unchecked.
          def self.from_model(election)
            stored = Array(election.census_settings.to_h["twofa_fields"]).map(&:to_s)
            new(sms: stored.include?("phone"), email: stored.include?("email"))
          end

          # SaaS-shape array — this is what gets stored and forwarded verbatim
          # to `twoFaFields` in the process-creation payload. Kept sorted so
          # two equivalent selections do not appear as different diffs.
          def two_fa_fields
            fields = []
            fields << "email" if email
            fields << "phone" if sms
            fields.sort
          end
        end
      end
    end
  end
end
