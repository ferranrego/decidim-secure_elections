# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Persists the second-factor choice from the Security tab into
        # `election.census_settings["twofa_fields"]` and re-runs the census
        # pre-flight so the Dashboard's Publish gate reflects the new state.
        #
        # The pre-flight rerun mirrors {AfterUpdateCensus}: a change in
        # `twoFaFields` changes what the SaaS validates (a voter with no
        # phone will be flagged as `missingData` the moment SMS OTP is
        # enabled), so the admin must see the result before Publish.
        class UpdateElectionSecurity < Decidim::Command
          # @param form     [AdminForms::SecurityForm]
          # @param election [Decidim::Elections::Vocdoni::Election]
          def initialize(form, election)
            @form = form
            @election = election
          end

          def call
            return broadcast(:invalid) if form.invalid?
            return broadcast(:invalid) unless election.editable?

            persist_two_fa_fields!
            rerun_preflight!

            broadcast(:ok)
          end

          private

          attr_reader :form, :election

          def persist_two_fa_fields!
            settings = election.census_settings.to_h.merge("twofa_fields" => form.two_fa_fields)
            election.update!(census_settings: settings)
          end

          # Mirrors AfterUpdateCensus: drop the stale ok:true before the job
          # runs, so a redirect that outraces the pre-flight cannot show a
          # confirmation for the previous state. `preview_census!` never
          # raises; its outcome lands on `process.metadata["census_validation"]`.
          def rerun_preflight!
            process = Vocdoni::Process.find_or_initialize_by(decidim_election_id: election.id)
            process.state ||= "pending"
            process.save!
            process.invalidate_census_validation!

            return if process.published?

            Decidim::Elections::Vocdoni::PushElectionJob.preview_census!(election.id)
          end
        end
      end
    end
  end
end
