# frozen_string_literal: true

# Phase-4 spike: proves the extension surface added to upstream
# decidim-elections (vocdoni/decidim#1, #2, integrated on
# `phase-4/integration`) is enough to plug the Vocdoni backend in as an
# optional "security layer" without patching any upstream file.
#
# Loaded only when the environment variable `PHASE_4_SPIKE=1` is set, so
# the existing `Decidim::Elections::Vocdoni` production code path is
# unaffected.

require "decidim/elections"

module Decidim
  module Elections
    module Vocdoni
    module Phase4Spike
      class Engine < ::Rails::Engine
        engine_name "decidim_elections_vocdoni_phase_4_spike"

        # Views + locales live under the spike's own path so nothing collides
        # with the main engine.
        paths["config/locales"] = "lib/decidim/elections/vocdoni/phase_4_spike/config/locales"

        # Registers the "Secure via Vocdoni" census manifest — the ONE thing
        # an admin picks. Everything else that makes an election "Vocdoni-
        # backed" (results anchored on chain, publish-locks-editing, voter
        # booth SPA) is a consequence of this choice; there is no separate
        # results-availability radio button to pick and no separate booth
        # setting to configure. That is why we deliberately do NOT register
        # a `:blockchain_backed` results_availability option — a stray choice
        # of "Blockchain-backed results" on a CSV census would be incoherent
        # and there is no way to enforce the coherence from the admin form.
        initializer "phase_4_spike.register_census_manifest" do
          Decidim::Elections.census_registry.register(:vocdoni_secure) do |manifest|
            manifest.admin_form = "Decidim::Elections::Vocdoni::AdminForms::CensusForm"
            manifest.admin_form_partial = "decidim/elections/vocdoni/admin/censuses/vocdoni_secure_form"
            manifest.after_update_command = "Decidim::Elections::Vocdoni::Admin::AfterUpdateCensus"
            manifest.voter_form = "Decidim::Elections::Vocdoni::VoterForms::PassthroughForm"
            manifest.voter_form_partial = "decidim/elections/vocdoni/booth/launcher"
            manifest.user_query do |election|
              # Stage A/B: the census is every registered user of the org,
              # capped at 20 for the spike so publish + memberbase upload
              # finish quickly against the stg SaaS. When we grow into real
              # deployments this cap goes away and the roster is picked
              # explicitly from the admin form.
              #
              # The cap is applied through a subquery because upstream's
              # `CensusManifest#users` composes an outer `.offset(page).limit(per_page)`
              # on the returned relation and an outer `.limit` on ActiveRecord
              # OVERRIDES a chained inner `.limit` on the same relation. A pluck
              # + `where(id: …)` sidesteps the composition entirely: the outer
              # `.limit` sees an id list and cannot expand it.
              ids = Decidim::User
                .where(organization: election.organization)
                .where.not(email: nil)
                .order(id: :asc)
                .limit(20)
                .pluck(:id)
              Decidim::User.where(id: ids)
            end
          end
        end

        # Decorate upstream `Decidim::Elections::Election` with a couple of
        # spike-specific behaviours. Runs on every code reload in development
        # (`to_prepare`) and once in production, after Zeitwerk has loaded the
        # upstream model. Idempotent.
        initializer "phase_4_spike.extend_election_model" do |app|
          app.config.to_prepare do
            # `has_one :vocdoni_process` so `election.vocdoni_process` reads
            # naturally from everywhere without the caller needing to know
            # about the sidecar table.
            Decidim::Elections::Election.has_one :vocdoni_process,
                                                 class_name: "Decidim::Elections::Vocdoni::Process",
                                                 foreign_key: "decidim_election_id",
                                                 dependent: :destroy,
                                                 inverse_of: :election

            # Publish is the point-of-no-return for a Vocdoni-backed election.
            # Upstream keeps the election editable until Start (see
            # `Election#editable?`: `published? ? !started? : !votes.exists?`)
            # — for us that is wrong: as soon as the census, the questions
            # and the endDate are anchored on chain, they cannot change.
            # Locking here also locks the census tab and the questions tab,
            # both of which gate on `election.editable?`
            # (see decidim-elections/app/permissions/…/admin/permissions.rb).
            Decidim::Elections::Election.prepend(
              Decidim::Elections::Vocdoni::PublishLocksEditing
            )
          end
        end

        # Injects a Security tab into upstream `Decidim::Elections::AdminEngine`
        # for `:vocdoni_secure` elections — the tab that owns the second-factor
        # choice (email OTP, SMS OTP, both, or none) forwarded to the SaaS as
        # `twoFaFields` at publish. Two hooks, both idempotent:
        #
        #  1. `routes.append` bolts `resource :security` onto the same nested
        #     `resources :elections` block upstream declares, so the URL sits
        #     next to the Census tab (`/elections/:id/security`). The
        #     controller is named with a leading slash to escape upstream's
        #     `isolate_namespace Decidim::Elections::Admin` — the class lives
        #     in `Decidim::Elections::Vocdoni::Admin`.
        #
        #  2. The `admin_elections_menu` block is called back every time the
        #     menu is rendered, so a bare census_manifest guard is enough to
        #     hide the tab on internal_users elections without touching the
        #     upstream item list.
        initializer "phase_4_spike.security_tab" do
          # Decidim raises unless every icon referenced by name is
          # pre-registered (`Decidim::IconRegistry#find`).
          Decidim.icons.register(name: "shield-keyhole-line",
                                 icon: "shield-keyhole-line",
                                 category: "system",
                                 description: "Security tab",
                                 engine: :core)

          Decidim::Elections::AdminEngine.routes.append do
            resources :elections, only: [] do
              resource :security, only: [:show, :update],
                                  controller: "/decidim/elections/vocdoni/admin/security"
            end
          end

          Decidim.menu :admin_elections_menu do |menu|
            election = @election
            next unless election.present? && election.census_manifest.to_s == "vocdoni_secure"

            proxy = Decidim::EngineRouter.admin_proxy(election.component)
            security_path = proxy&.election_security_path(election)
            menu.add_item :vocdoni_security,
                          I18n.t("security", scope: "decidim.admin.menu.elections_menu"),
                          security_path,
                          active: security_path.present? && is_active_link?(security_path),
                          icon_name: "shield-keyhole-line"
          end
        end

        # Enqueues {PushElectionJob} whenever a Vocdoni-backed election is
        # published from the Decidim admin. The subscription piggybacks on the
        # `decidim.elections.admin.publish_election:after` notification added
        # by vocdoni/decidim#2 (see phase-4/integration).
        #
        # `Decidim::Command#with_events` publishes via
        # `ActiveSupport::Notifications.publish(name, **event_arguments)`,
        # not `.instrument`. Subscribers therefore receive a 2-arg block —
        # `|event_name, data|` — where `data` is the kwargs hash, not the
        # standard 5-arg `|name, started, finished, id, payload|` shape that
        # `instrument` uses.
        initializer "phase_4_spike.subscribe_to_publish" do
          ActiveSupport::Notifications.subscribe("decidim.elections.admin.publish_election:after") do |_event_name, data|
            election = data[:election]
            next if election.blank?

            Rails.logger.info "[phase-4-spike] publish_election:after fired for election ##{election.id} (manifest=#{election.census_manifest.inspect})"

            if election.census_manifest.to_s == "vocdoni_secure"
              Decidim::Elections::Vocdoni::PushElectionJob.perform_later(election.id)
              Rails.logger.info "[phase-4-spike] enqueued PushElectionJob for election ##{election.id}"
            end
          end
        end
      end
    end
  end
end
end
