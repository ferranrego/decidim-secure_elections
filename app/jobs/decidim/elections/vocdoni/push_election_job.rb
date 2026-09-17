# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Enqueued from a subscriber to
      # `decidim.elections.admin.publish_election:after` (upstream event added
      # by vocdoni/decidim#2, integrated on `phase-4/integration`) whenever a
      # Vocdoni-backed election is published from the Decidim admin.
      #
      # Talks to the Vocdoni SaaS API through the shared {ApiClient} and lands
      # the process on chain:
      #
      #   add members → create group → validate group →
      #   create census → publish census → create process → publish process →
      #   persist ids on the {Process} sidecar.
      #
      # The Vocdoni-side state (process id, chain id, group id, per-question
      # upstream ids) is written into the {Process} sidecar row that
      # {Admin::AfterUpdateCensus} bootstrapped in state `pending`.
      # `Decidim::Elections::Election` and its associated tables are read-only
      # from this job's point of view.
      #
      # Only handles elections whose `census_manifest` is `"vocdoni_secure"`;
      # everything else is left alone. The subscriber that enqueues it filters
      # on the manifest, but the job double-checks so a manually enqueued run
      # cannot publish a non-Vocdoni election.
      #
      # This is a Stage-B port of the legacy `PublishElectionJob` from the
      # standalone module: same steps, same retry-safety rules, but the state
      # it reads and writes is the upstream Election plus the sidecar Process,
      # not a Vocdoni-owned Election model.
      class PushElectionJob < ApplicationJob
        # A stg-only queue so the "main" Sidekiq (which runs the legacy
        # `PublishElectionJob` on the `:vocdoni` queue for
        # decidim.vocdoni.io) never picks up a stg-spike job it does not
        # know how to load. The stg Sidekiq is the only one listening on
        # `:vocdoni_spike`, so there is no cross-contamination.
        queue_as :vocdoni_spike

        # Only transient failures (network flap, 5xx, 429) are retried — a
        # permanent rejection (4xx or a 2xx with `errors` in the body) fails
        # identically on retry and, when the failing call is `POST /members`,
        # creates fresh duplicated members upstream on each attempt.
        retry_on Decidim::Elections::Vocdoni::ApiError, wait: :polynomially_longer, attempts: 3

        MEMBER_IDENTITY_FIELDS = %w(memberNumber nationalId email phone).freeze

        # Defensive bound on the memberbase pagination walk.
        MAX_MEMBER_PAGES = 200

        # Map from the Census-tab credential-field names onto the SaaS's own
        # camelCase names used inside `authFields`. `email` and `phone` are
        # deliberately absent: the SaaS rejects them as authFields (proven
        # by /processes/census/validation, which 400s on any payload that
        # names either — with or without an overlapping twoFaFields entry).
        # They are 2FA-only from the SaaS's perspective and live in
        # `census_settings["twofa_fields"]`, driven by the Security tab.
        AUTH_FIELD_MAP = {
          "member_number" => "memberNumber",
          "national_id"   => "nationalId",
          "date_of_birth" => "birthDate",
          "name"          => "name"
        }.freeze

        def perform(election_id, scheduled_start_at = nil)
          return unless bootstrap!(election_id)
          return if published_upstream?
          # Someone else — the manual-start subscriber or a previous run —
          # is already pushing this election. Skipping avoids duplicate SaaS
          # resources on manual+scheduled overlap.
          return if process.publishing?
          # Self-invalidation for scheduled pushes: if the admin rescheduled
          # start_at after this job was enqueued, the model's
          # `after_update_commit` (see the reschedule_push_on_start_at_change
          # initializer) enqueued a fresh job for the new timestamp. This
          # stale copy silently no-ops. Compared at second precision — that
          # is the precision an admin can control from the form, and it
          # sidesteps a microsecond diff between the model's Time and the
          # ActiveJob-serialized Time we get back here.
          if scheduled_start_at.present?
            expected_at = scheduled_start_at.respond_to?(:to_i) ? scheduled_start_at : Time.zone.parse(scheduled_start_at.to_s)
            return if election.start_at.nil? || election.start_at.to_i != expected_at.to_i
          end

          Decidim::Elections::Vocdoni.validate_configuration!

          process.update!(state: "publishing")

          prepare_census!
          ensure_process_created!
          ensure_process_published!
          persist_process_metadata!

          process.update!(state: "published")

          # Kick off the on-chain state monitor so the sidecar keeps mirroring
          # the SaaS while voting is open. `SyncProcessJob` re-schedules itself
          # while the process is still ongoing.
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          record_step_failure!(e)
          # If a process id was already saved, the SaaS may still confirm it
          # asynchronously — keep the monitor polling.
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id) if process.vocdoni_process_id.present?
          raise if e.transient?
        rescue StandardError => e
          record_step_failure!(e)
          Decidim::Elections::Vocdoni::SyncProcessJob.perform_later(election.id) if process.vocdoni_process_id.present?
          raise
        end

        # Runs only the census-preparation phase — push members, create the
        # group, validate — and records the outcome in
        # `process.metadata["census_validation"]`. Used by
        # {Admin::AfterUpdateCensus} so the Census tab reflects a real
        # dry-run status before the admin ever clicks Publish, and by the
        # Dashboard to gate that Publish button (the guard reads
        # `process.census_valid?`).
        #
        # Idempotent by construction: `ensure_members_pushed!` and
        # `ensure_group_created!` skip work that a previous attempt (or the
        # full publish) already did, so calling this at every census save is
        # cheap after the first time.
        #
        # Never raises: a validation failure is an *answer* the admin needs to
        # see, not a job crash. Everything is captured on the process record.
        def self.preview_census!(election_id)
          new.send(:run_preview!, election_id)
        end

        private

        attr_reader :process

        def vocdoni_backed?
          election.census_manifest.to_s == "vocdoni_secure"
        end

        def published_upstream?
          process.vocdoni_process_id.present? && process.published?
        end

        # Common setup for both `perform` and `preview_census!`. Returns true
        # when there is something to do, false when the election is missing
        # or not Vocdoni-backed. Rebinds `@election` because `ApplicationJob`'s
        # own `attr_reader :election` is protected and shared across attempts.
        def bootstrap!(election_id)
          @election = Decidim::Elections::Election.find_by(id: election_id)
          return false if election.blank?
          return false unless vocdoni_backed?

          @process = election.vocdoni_process || Process.create!(decidim_election_id: election.id, state: "pending")
          true
        end

        # The three steps that reach the point where we can *tell* whether the
        # census works: push members, create the group, validate. Extracted
        # so the preview path and the full publish path share the exact same
        # code — anything that succeeds here will also succeed on Publish.
        # On success, records `ok: true` on the process so the Dashboard's
        # Publish gate can unblock.
        def prepare_census!
          ensure_members_pushed!
          ensure_group_created!
          ensure_census_validated!
          process.record_census_validation!(ok: true, size: census_users.size)
        end

        # Ran by `preview_census!`. Catches errors and records them; never
        # raises — the admin sees the result on the next page render.
        def run_preview!(election_id)
          return unless bootstrap!(election_id)
          return if published_upstream?

          Decidim::Elections::Vocdoni.validate_configuration!

          prepare_census!
        rescue Decidim::Elections::Vocdoni::ApiError => e
          record_preview_failure!(e)
        rescue StandardError => e
          record_preview_failure!(e)
        end

        # SaaS 400s carry `{"error":..., "code":..., "data":{...}}` as JSON;
        # Faraday's json middleware only parses it into a Hash when the
        # response's `Content-Type` matches `/\bjson$/`, so anything with a
        # `; charset=utf-8` suffix (or a proxy that stripped it) leaves us
        # with the raw body as a String. Fall back to a manual JSON parse
        # so `data.duplicates` / `data.missingData` reach the admin either
        # way.
        def extract_error_data(error)
          return nil unless error.respond_to?(:body)

          body = error.try(:body)
          body = (JSON.parse(body) rescue nil) if body.is_a?(String)
          return nil unless body.is_a?(Hash)

          body["data"]
        end

        # Called from both rescue arms of `perform`. Persists the failure
        # against the process (state: failed, last_error) AND, when the step
        # that blew up was the census pre-flight, mirrors the payload into
        # `census_validation` so the same Dashboard gate that reads a preview
        # ok=false also reads a publish-time ok=false.
        def record_step_failure!(error)
          message = redact(error.message)
          body_data = extract_error_data(error)
          error_code = error.respond_to?(:code) ? error.try(:code) : nil

          process.record_failure!(message, step: @step, code: error_code, data: body_data)

          return unless @step == "validate_census"

          process.record_census_validation!(
            ok: false,
            step: @step,
            code: error_code,
            message: message,
            data: body_data
          )
        end

        # Mirror of `record_step_failure!` for the preview path — same
        # `census_validation` shape, no state change. A preview failure at
        # any step (add_members, create_group, validate_census) is still an
        # actionable answer for the admin, so we surface it under the same
        # metadata key.
        def record_preview_failure!(error)
          message = redact(error.message)
          body_data = extract_error_data(error)
          error_code = error.respond_to?(:code) ? error.try(:code) : nil

          process.record_census_validation!(
            ok: false,
            step: @step,
            code: error_code,
            message: message,
            data: body_data
          )
        end

        # ---------------------------------------------------------------------
        # Census
        # ---------------------------------------------------------------------

        def ensure_members_pushed!
          @step = "add_members"
          # Skip when we already have a group id from a previous attempt.
          return if process.census_group_id.present?

          payloads = voter_payloads
          if payloads.empty?
            raise Decidim::Elections::Vocdoni::ApiError.new(
              "This election's census resolves to zero voters — nothing to push to the Vocdoni memberbase",
              transient: false
            )
          end

          # POST /organizations/{addr}/members is *not* upsert-by-memberNumber
          # upstream: pushing the same roster twice creates fresh OrgMember docs
          # with duplicate memberNumbers, and the census publish then dupe-keys
          # on the (censusId, loginHash) unique index because the clones all
          # hash to the same auth-field value. Filter by what is already there.
          existing = upstream_member_index
          # Index keys are lowercased+stripped; mirror that when looking up.
          fresh = payloads.reject { |p| existing.key?("memberNumber:#{p["memberNumber"].to_s.strip.downcase}") }
          if fresh.empty?
            # Every voter is already in the memberbase from a previous attempt
            # — skip the POST and let ensure_group_created! reuse the ids.
            return
          end

          response = client.organizations.add_members(org_address, fresh).to_h
          await_job!(response["jobId"])
          # The push added rows the memoized index has not seen; drop it so
          # resolve_member_ids! rewalks and picks up the new ids.
          @upstream_member_index = nil

          errors = Array(response["errors"]).map(&:to_s).compact_blank
          return if errors.empty?

          raise Decidim::Elections::Vocdoni::ApiError.new(
            "The Vocdoni memberbase rejected #{errors.size} of #{fresh.size} voters: #{errors.join("; ")}",
            body: response,
            transient: false
          )
        end

        def ensure_group_created!
          return if process.census_group_id.present?

          @step = "create_group"
          member_ids = resolve_member_ids!
          if member_ids.empty?
            raise Decidim::Elections::Vocdoni::ApiError.new(
              "None of the census voters could be identified in the Vocdoni memberbase",
              transient: false
            )
          end

          response = client.organizations.create_group(
            org_address,
            title: group_title,
            description: group_description,
            member_ids:
          ).to_h

          group_id = response["id"].presence
          raise Decidim::Elections::Vocdoni::ApiError.new("POST /organizations/{addr}/groups returned no id", body: response, transient: false) if group_id.blank?

          process.update!(census_group_id: group_id)
        end

        # Pre-flight check that the census's authFields/twoFaFields produce
        # unique, complete credentials over the group members. In the old API
        # this took two steps — `POST /organizations/{addr}/groups/{gid}/
        # validate` then `POST /census/{id}/group/{gid}/publish` — but the new
        # multi-question API carries the census inline in `POST /processes` and
        # publishes it as part of `POST /processes/{id}/publish`. The only
        # thing left to do here is the pre-flight, which is `POST /processes/
        # census/validation`. Its body accepts the very same census spec
        # {#census_payload} builds for `POST /processes`, so we hand that in.
        def ensure_census_validated!
          @step = "validate_census"
          client.elections.validate_census(org_address, census_payload)
        rescue Decidim::Elections::Vocdoni::ApiError => e
          # A 400 here is an actionable answer, not a fault — the census is
          # unable to authenticate its own members. Bubble it up so
          # `record_failure!` catches it; it is non-transient.
          raise Decidim::Elections::Vocdoni::ApiError.new(
            e.message.to_s,
            body: e.try(:body),
            status: e.try(:status),
            code: e.try(:code),
            transient: false
          ) if e.status == 400

          raise
        end

        # ---------------------------------------------------------------------
        # Process
        # ---------------------------------------------------------------------

        def ensure_process_created!
          return if process.vocdoni_process_id.present?

          @step = "create_process"
          response = client.elections.create(process_payload).to_h
          process_id = response["processId"].presence
          raise Decidim::Elections::Vocdoni::ApiError.new("POST /processes returned no processId", body: response, transient: false) if process_id.blank?

          process.update!(vocdoni_process_id: process_id)
        end

        def ensure_process_published!
          remote = remote_process
          return if live_upstream?(remote)

          @step = "publish_process"
          response = client.elections.publish(process.vocdoni_process_id).to_h
          await_job!(response["jobId"])
          @remote_process = nil
        end

        def persist_process_metadata!
          @step = "persist"
          remote = remote_process

          questions_meta = election.questions.each_with_index.map do |question, index|
            upstream = remote_question_for(remote, question, index)
            next nil if upstream.blank?

            {
              "decidim_question_id" => question.id,
              "vocdoni_question_id" => (upstream["id"] || upstream["questionId"]).to_s.presence,
              "vocdoni_upstream_id" => upstream["upstreamId"].to_s.presence,
              "vocdoni_status"      => upstream["status"].to_s.presence
            }
          end.compact

          size = remote_census_size(remote) || process.census_size
          process.update!(
            chain_id: remote["chainId"].to_s.presence,
            vocdoni_upstream_id: remote["upstreamId"].to_s.presence,
            census_size: size,
            metadata: process.metadata.merge("questions" => questions_meta)
          )
        end

        def remote_process
          @remote_process ||= client.elections.get(process.vocdoni_process_id).to_h
        end

        def live_upstream?(remote)
          return true if remote["published"] == true

          %w(READY ONGOING ENDED RESULTS PAUSED).include?(remote["status"].to_s)
        end

        def remote_question_for(remote, question, index)
          questions = Array(remote["questions"])
          return nil if questions.empty?

          questions[index]
        end

        def remote_census_size(remote)
          size = remote.dig("census", "size") || remote["censusSize"]
          size&.to_i
        end

        # ---------------------------------------------------------------------
        # Voter roster
        # ---------------------------------------------------------------------

        # Runs the census-manifest's `user_query` block (registered in the
        # module engine, see `phase_4_spike.rb`) and turns each row into an
        # API-shaped member payload.
        def voter_payloads
          @voter_payloads ||= census_users.map { |user| user_to_member(user) }.compact_blank
        end

        # Walks the census-manifest's `#users` iterator (which delegates to the
        # `user_query` block we registered on the manifest) to build the roster
        # for this election. `CensusManifest#users` paginates by 5 by default;
        # we ask for the full list in one shot with an oversized limit — the
        # spike's stg census is a handful of test users. When this grows into
        # real deployment the loop can be turned into a proper pager.
        def census_users
          manifest = Decidim::Elections.census_registry.find(:vocdoni_secure)
          return [] unless manifest

          Array(manifest.users(election, 0, 100_000))
        end

        # Maps a `Decidim::User` onto the Vocdoni memberbase schema. The
        # `memberNumber` is the Decidim user id — stable, unique, and lets a
        # returning voter match up on the same identity across retries.
        def user_to_member(user)
          {
            "memberNumber" => user.id.to_s,
            "name" => user.name.to_s.strip.presence,
            "email" => user.email.to_s.strip.presence
          }.compact
        end

        def resolve_member_ids!
          @step = "list_members"
          index = upstream_member_index

          census_users.map do |user|
            id = index["memberNumber:#{user.id}"] ||
                 (user.email.present? && index["email:#{user.email.strip.downcase}"])

            next nil if id.blank?

            id
          end.compact
        end

        # Memoized so ensure_members_pushed! (which reads it to dedupe against
        # the memberbase) and resolve_member_ids! (which reads it to look up
        # ids for the group) share one walk. Callers that add members must
        # invalidate `@upstream_member_index` so the next read rewalks.
        def upstream_member_index
          return @upstream_member_index if @upstream_member_index

          index = {}
          page = 1
          pages = 0

          while pages < MAX_MEMBER_PAGES
            response = client.organizations.members(org_address, page:).to_h
            members = Array(response["members"]).grep(Hash)
            break if members.empty?

            members.each do |member|
              id = member["id"].presence
              next if id.blank?

              MEMBER_IDENTITY_FIELDS.each do |field|
                value = member[field].to_s.strip.downcase
                next if value.blank?

                index["#{field}:#{value}"] ||= id
              end
            end

            pages += 1
            next_page = response.dig("pagination", "nextPage").to_i
            break if next_page <= page

            page = next_page
          end

          @upstream_member_index = index
        end

        # ---------------------------------------------------------------------
        # Payload
        # ---------------------------------------------------------------------

        def process_payload
          payload = {
            "orgAddress" => org_address,
            "title" => localize(election.title),
            "description" => localize(election.description) || localize(election.title),
            "endDate" => election.end_at,
            "census" => census_payload,
            "questions" => election.questions.map { |question| question_payload(question) }
          }

          payload["startDate"] = election.start_at if election.start_at.present?

          payload
        end

        def census_payload
          payload = {
            "authFields" => auth_fields,
            "groupId" => process.census_group_id
          }
          payload["twoFaFields"] = two_fa_fields if two_fa_fields.any?
          payload
        end

        # Upstream Decidim uses `single_option` / `multiple_option`; the SaaS
        # accepts lowercase `singlechoice` / `multichoice` and rejects
        # anything else with code 40037.
        QUESTION_TYPE_MAP = {
          "single_option"   => "singlechoice",
          "multiple_option" => "multichoice"
        }.freeze

        def question_payload(question)
          type = QUESTION_TYPE_MAP.fetch(question.question_type.to_s, question.question_type.to_s)

          payload = {
            "title" => localize(question.body),
            "type" => type,
            "choices" => question.response_options.order(:id).map.with_index do |option, idx|
              { "title" => localize(option.body), "value" => idx }
            end
          }

          description = localize(question.description)
          payload["description"] = description if description.present?

          # Only multichoice carries typeSetup: singlechoice ignores it, ranked
          # and cumulative reject it (see saas-backend api/processes.go). And
          # multichoice's typeSetup is just the bounds — `uniqueChoices` is
          # rejected because each choice is an independent 0/1 field, so a
          # duplicate is already impossible.
          if type == "multichoice"
            max = question.max_choices.to_i
            payload["typeSetup"] = {
              "maxChoices" => [max, 1].max,
              "minChoices" => question.mandatory? ? 1 : 0
            }
          end

          payload
        end

        # ---------------------------------------------------------------------
        # Config
        # ---------------------------------------------------------------------

        # The credential fields the admin ticked on the Census tab, mapped
        # onto the SaaS's own names. `memberNumber` is always in authFields
        # whether the admin picked it or not, because the census still needs
        # at least one authField and every roster row we push carries a
        # stable member number (`Decidim::User#id`).
        def credential_field_selection
          Array(election.census_settings["credential_fields"]).map(&:to_s)
        end

        def auth_fields
          picked = credential_field_selection
          fields = picked.filter_map { |f| AUTH_FIELD_MAP[f] }
          fields << "memberNumber" unless fields.include?("memberNumber")
          fields.uniq
        end

        # Second-factor selection lives on the Security tab and is written
        # into `census_settings["twofa_fields"]` verbatim in SaaS shape
        # (`["email"]`, `["phone"]`, `["email","phone"]` or `[]`). An
        # election that has never visited the Security tab has no key here
        # and the SaaS payload gets no `twoFaFields` at all — CSP auth only.
        def two_fa_fields
          Array(election.census_settings["twofa_fields"]).map(&:to_s)
        end

        def org_address
          Decidim::Elections::Vocdoni.org_address
        end

        def group_title
          title = localize(election.title).to_h["default"].presence || "Decidim election"
          "#{title.truncate(180)} (##{election.id})"
        end

        def group_description
          "Census of Decidim election ##{election.id}. Managed by Decidim; do not edit by hand."
        end

        def default_locale
          @default_locale ||= (election.organization&.default_locale || Decidim.default_locale || I18n.default_locale).to_s
        end
      end
    end
  end
end
