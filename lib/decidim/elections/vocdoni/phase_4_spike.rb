# frozen_string_literal: true

# Phase-4 spike: proves the extension surface added to upstream
# decidim-elections (vocdoni/decidim#1, #2, integrated on
# `phase-4/integration`) is enough to plug the Vocdoni backend in as an
# optional "security layer" without patching any upstream file.
#
# Under `PHASE_4_SPIKE=1` the four upstream tabs — Main, Questions,
# Census, Dashboard — are left untouched (identical to `try.decidim.org`).
# The only surface we add is a fifth admin tab, "Security", which is
# where an administrator opts in to Vocdoni-backed voting and configures
# the second-factor challenge. Opt-in is materialised by the presence of
# a `Decidim::Elections::Vocdoni::Process` sidecar row keyed to the
# election.

require "decidim/elections"

module Decidim
  module Elections
    module Vocdoni
    module Phase4Spike
      class Engine < ::Rails::Engine
        engine_name "decidim_elections_vocdoni_phase_4_spike"

        paths["config/locales"] = "lib/decidim/elections/vocdoni/phase_4_spike/config/locales"

        # Decorate upstream `Decidim::Elections::Election` with two spike-
        # specific behaviours. Runs on every code reload in development
        # (`to_prepare`) and once in production after Zeitwerk has loaded
        # the upstream model. Idempotent.
        initializer "phase_4_spike.extend_election_model" do |app|
          app.config.to_prepare do
            # `has_one :vocdoni_process` so `election.vocdoni_process` reads
            # naturally from everywhere without the caller needing to know
            # about the sidecar table. The sidecar's presence doubles as the
            # opt-in signal now that the Security tab owns opt-in.
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
            Decidim::Elections::Election.prepend(
              Decidim::Elections::Vocdoni::PublishLocksEditing
            )
          end
        end

        # Injects a Security tab into upstream `Decidim::Elections::AdminEngine`.
        # The tab is where an admin opts in to Vocdoni voting for the election
        # (Enable checkbox) and picks the second-factor challenge forwarded to
        # the SaaS as `twoFaFields` at publish. Two hooks, both idempotent:
        #
        #   1. `routes.append` bolts `resource :security` onto the same nested
        #      `resources :elections` block upstream declares, so the URL sits
        #      next to the Census tab (`/elections/:id/security`). The
        #      controller is named with a leading slash to escape upstream's
        #      `isolate_namespace Decidim::Elections::Admin` — the class lives
        #      in `Decidim::Elections::Vocdoni::Admin`.
        #
        #   2. The `admin_elections_menu` block is called back every time the
        #      menu is rendered. The item is always visible so the admin can
        #      discover the Vocdoni option without extra ceremony.
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
            next if election.blank?

            proxy = Decidim::EngineRouter.admin_proxy(election.component)
            security_path = proxy&.election_security_path(election)
            # Position 3.5 slots the tab between Census (position 3, upstream
            # order) and Dashboard (position 4) without depending on either
            # item's implementation detail — Decidim::Menu sorts by float and
            # 3.5 sits between them regardless of future upstream additions
            # at the ends.
            menu.add_item :vocdoni_security,
                          I18n.t("security", scope: "decidim.admin.menu.elections_menu"),
                          security_path,
                          active: security_path.present? && is_active_link?(security_path),
                          icon_name: "shield-keyhole-line",
                          position: 3.5
          end
        end

        # Enqueues {PublishToVocdoniJob} whenever an election that has opted
        # in to Vocdoni is published from the Decidim admin. Opt-in is
        # signalled by the presence of the {Process} sidecar (created from
        # the Security tab). The subscription piggybacks on the
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

            Rails.logger.info "[phase-4-spike] publish_election:after fired for election ##{election.id} (vocdoni=#{election.vocdoni_process.present?})"

            if election.vocdoni_process.present?
              Decidim::Elections::Vocdoni::PublishToVocdoniJob.perform_later(election.id)
              Rails.logger.info "[phase-4-spike] enqueued PublishToVocdoniJob for election ##{election.id}"
            end
          end
        end
      end
    end
  end
end
end
