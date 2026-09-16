# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Security tab (vocdoni_secure only). Owns the second-factor choice
        # — email OTP, SMS OTP, both, or none — that the publish job forwards
        # verbatim as `twoFaFields` when it creates the process on Vocdoni's
        # SaaS. Storage is `election.census_settings["twofa_fields"]`.
        #
        # Inherits from upstream's `Decidim::Elections::Admin::ApplicationController`
        # rather than the Vocdoni admin base, because in the phase-4 spike
        # the elections component uses upstream's admin engine and its
        # controllers work off `Decidim::Elections::Election`, not the
        # Vocdoni-only Election model.
        class SecurityController < ::Decidim::Elections::Admin::ApplicationController
          helper_method :election

          def show
            enforce_permission_to(:update, :census, election:)

            @form = security_form
          end

          def update
            enforce_permission_to(:update, :census, election:)

            @form = form(AdminForms::SecurityForm).from_params(params)

            UpdateElectionSecurity.call(@form, election) do
              on(:ok) do
                flash[:notice] = I18n.t("security.update.success", scope: "decidim.elections.vocdoni.admin")
                redirect_to election_security_path(election)
              end

              on(:invalid) do
                flash.now[:alert] = I18n.t("security.update.invalid", scope: "decidim.elections.vocdoni.admin")
                render action: "show", status: :unprocessable_content
              end
            end
          end

          private

          def election
            @election ||= ::Decidim::Elections::Election.where(component: current_component).find(params[:election_id])
          end

          def security_form
            AdminForms::SecurityForm.from_model(election)
          end
        end
      end
    end
  end
end
