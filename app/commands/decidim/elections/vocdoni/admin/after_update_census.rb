# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Runs after upstream's `ProcessCensus` command has persisted
        # `election.census_manifest = "vocdoni_secure"` and
        # `election.census_settings = form.census_settings` — that is, after
        # the admin saves the Census tab for a Vocdoni-backed election.
        #
        # Registered via `manifest.after_update_command = ...` in the engine.
        #
        # Its jobs:
        #   1. Make sure a `Vocdoni::Process` sidecar row exists for the
        #      election in the `pending` state, so downstream code (publish
        #      subscriber, dashboard, monitor) can find it.
        #   2. Run the census pre-flight against the SaaS
        #      (`POST /processes/census/validation`) so the admin never
        #      reaches the Dashboard's Publish button with a broken auth
        #      configuration. The result lands on
        #      `process.metadata["census_validation"]` and is what
        #      `process.census_valid?` reads.
        #
        # The pre-flight is synchronous with save on purpose: the admin's
        # mental model is "I saved the tab, tell me if it works". `preview_
        # census!` is idempotent (members already in the memberbase are
        # skipped, an existing group is reused), so subsequent saves after
        # the first roster upload are cheap.
        class AfterUpdateCensus
          def self.call(form, election)
            return unless form.valid?

            process = Vocdoni::Process.find_or_initialize_by(decidim_election_id: election.id)
            process.state ||= "pending"
            process.save!

            # Drop the stale ok before we start; a redirect that outraced the
            # pre-flight would otherwise show the previous ok:true beside
            # freshly-changed auth fields.
            process.invalidate_census_validation!

            # Skip the pre-flight once the election is already anchored on
            # chain: the census cannot change from that point, and the SaaS
            # call would still hit the memberbase for no reason.
            return process if process.published?

            Decidim::Elections::Vocdoni::PublishToVocdoniJob.preview_census!(election.id)
            process.reload
          end
        end
      end
    end
  end
end
