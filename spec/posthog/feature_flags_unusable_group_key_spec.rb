# frozen_string_literal: true

require 'spec_helper'

module PostHog
  # A usable group key is a non-empty string or a number. Any other key counts as no key: a condition
  # aggregated on that group type is skipped, and a flag whose conditions are all skipped resolves false
  # locally without a /flags request.
  describe 'unusable group keys' do
    let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }
    let(:remote_response) do
      { flags: { 'org-flag' => { key: 'org-flag', enabled: true, variant: nil, metadata: { id: 9 } } } }
    end
    let(:group_type_mapping) { { '0' => 'organization' } }

    unusable_group_keys = { 'an empty string' => '', 'nil' => nil, 'true' => true, 'false' => false,
                            'an array' => [], 'a hash' => {}, 'a non-empty array' => ['acme'],
                            'a non-empty hash' => { id: 'acme' } }

    def local_client(*flags)
      stub_request(:get, definitions_endpoint).to_return(
        status: 200, body: { flags: flags, cohorts: {}, group_type_mapping: group_type_mapping }.to_json
      )
      stub_request(:post, flags_endpoint).to_return(status: 200, body: remote_response.to_json)
      Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
    end

    def condition(*properties, rollout_percentage: 100, **extra)
      { properties: properties, rollout_percentage: rollout_percentage }.merge(extra)
    end

    def org_flag(key = 'org-flag', *conditions)
      conditions = [condition] if conditions.empty?
      { id: 1, key: key, active: true, filters: { aggregation_group_type_index: 0, groups: conditions } }
    end

    def person_flag(key, *conditions)
      { id: 2, key: key, active: true, filters: { groups: conditions } }
    end

    # A person condition on `plan`, plus a group condition aggregated on organization that matches any
    # organization.
    def mixed_flag
      person_flag('mixed', condition({ key: 'plan', operator: 'exact', value: 'pro', type: 'person' }),
                  condition(aggregation_group_type_index: 0))
    end

    def flag_dependency(key)
      { key: key, type: 'flag', value: true, operator: 'flag_evaluates_to', dependency_chain: [key] }
    end

    unusable_group_keys.each do |description, group_key|
      context "with #{description} as the group key" do
        let(:groups) { { organization: group_key } }

        it 'resolves a group flag to false in local-only mode' do
          c = local_client(org_flag)

          snapshot = c.evaluate_flags('user-1', groups: groups, only_evaluate_locally: true)

          expect(snapshot.get_flag('org-flag')).to be(false)
          expect(snapshot.unresolved_flags).to eq({})
        end

        it 'resolves a group flag to false with the default getter without a remote request' do
          c = local_client(org_flag)

          snapshot = c.evaluate_flags('user-1', flag_keys: ['org-flag'], groups: groups)

          expect(snapshot.get_flag('org-flag')).to be(false)
          expect(WebMock).not_to have_requested(:post, flags_endpoint)
        end

        it 'resolves a group flag to false with the single-flag getter without a remote request' do
          c = local_client(org_flag)

          result = c.get_feature_flag_result('org-flag', 'user-1', groups: groups, send_feature_flag_events: false)

          expect(result.value).to be(false)
          expect(WebMock).not_to have_requested(:post, flags_endpoint)
        end

        it 'skips the group condition of a mixed flag and lets the person condition decide' do
          c = local_client(mixed_flag)

          free = c.evaluate_flags('user-1', groups: groups, person_properties: { plan: 'free' },
                                            only_evaluate_locally: true)
          pro = c.evaluate_flags('user-1', groups: groups, person_properties: { plan: 'pro' },
                                           only_evaluate_locally: true)

          expect(free.get_flag('mixed')).to be(false)
          expect(pro.get_flag('mixed')).to be(true)
          expect(WebMock).not_to have_requested(:post, flags_endpoint)
        end

        it 'resolves a group-aggregated dependency to false' do
          child = person_flag('person-child', condition(flag_dependency('org-parent')))
          c = local_client(org_flag('org-parent'), child)

          snapshot = c.evaluate_flags('user-1', flag_keys: ['person-child'], groups: groups)

          expect(snapshot.get_flag('person-child')).to be(false)
          expect(snapshot.unresolved_flags).to eq({})
          expect(WebMock).not_to have_requested(:post, flags_endpoint)
        end

        it 'does not raise from get_all_flags or get_all_flags_and_payloads' do
          c = local_client(org_flag, mixed_flag)

          inputs = { groups: groups, person_properties: { plan: 'free' }, only_evaluate_locally: true }

          expect(c.get_all_flags('user-1', **inputs)).to eq('org-flag' => false, 'mixed' => false)
          expect(c.get_all_flags_and_payloads('user-1', **inputs)[:featureFlags])
            .to eq('org-flag' => false, 'mixed' => false)
        end

        it 'does not raise from capture with send_feature_flags' do
          c = local_client(org_flag)

          c.capture(distinct_id: 'user-1', event: 'signed_up', groups: groups, send_feature_flags: true)

          properties = c.dequeue_last_message[:properties]
          expect(properties['$feature/org-flag']).to be(false)
          expect(WebMock).not_to have_requested(:post, flags_endpoint)
        end
      end
    end

    # Each condition uses its own aggregation: an explicit null aggregation_group_type_index is a person
    # condition even when the flag aggregates by a group. Only conditions aggregated on a group without a
    # usable key are skipped, as the flags service does.
    describe 'a group flag with a person condition' do
      let(:plan_is_pro) { { key: 'plan', operator: 'exact', value: 'pro', type: 'person' } }

      def person_condition_org_flag(key = 'org-flag')
        org_flag(key, condition(plan_is_pro, aggregation_group_type_index: nil))
      end

      [{}, { organization: '' }].each do |groups|
        context "with groups #{groups.inspect}" do
          it 'lets the person condition decide without a remote request' do
            c = local_client(person_condition_org_flag)

            pro = c.evaluate_flags('user-1', flag_keys: ['org-flag'], groups: groups,
                                             person_properties: { plan: 'pro' })
            free = c.evaluate_flags('user-1', flag_keys: ['org-flag'], groups: groups,
                                              person_properties: { plan: 'free' })
            result = c.get_feature_flag_result('org-flag', 'user-1', groups: groups,
                                                                     person_properties: { plan: 'pro' },
                                                                     send_feature_flag_events: false)

            expect(pro.get_flag('org-flag')).to be(true)
            expect(free.get_flag('org-flag')).to be(false)
            expect(result.value).to be(true)
            expect(WebMock).not_to have_requested(:post, flags_endpoint)
          end

          it 'resolves a dependent person flag from it without a remote request' do
            child = person_flag('person-child', condition(flag_dependency('org-parent')))
            c = local_client(person_condition_org_flag('org-parent'), child)

            pro = c.evaluate_flags('user-1', flag_keys: ['person-child'], groups: groups,
                                             person_properties: { plan: 'pro' })
            free = c.evaluate_flags('user-1', flag_keys: ['person-child'], groups: groups,
                                              person_properties: { plan: 'free' })

            expect(pro.get_flag('person-child')).to be(true)
            expect(free.get_flag('person-child')).to be(false)
            expect(WebMock).not_to have_requested(:post, flags_endpoint)
          end

          it 'skips a group condition before the person condition' do
            c = local_client(org_flag('org-flag', condition, condition(plan_is_pro, aggregation_group_type_index: nil)))

            pro = c.evaluate_flags('user-1', flag_keys: ['org-flag'], groups: groups,
                                             person_properties: { plan: 'pro' })
            free = c.evaluate_flags('user-1', flag_keys: ['org-flag'], groups: groups,
                                              person_properties: { plan: 'free' })

            expect(pro.get_flag('org-flag')).to be(true)
            expect(free.get_flag('org-flag')).to be(false)
            expect(WebMock).not_to have_requested(:post, flags_endpoint)
          end

          it 'sets the captured flag from the person condition' do
            c = local_client(person_condition_org_flag)

            %w[pro free].each do |plan|
              options = SendFeatureFlagsOptions.new(only_evaluate_locally: true, person_properties: { plan: plan })
              c.capture(distinct_id: 'user-1', event: 'signed_up', groups: groups, send_feature_flags: options)

              expect(c.dequeue_last_message[:properties]['$feature/org-flag']).to be(plan == 'pro')
            end
            expect(WebMock).not_to have_requested(:post, flags_endpoint)
          end
        end
      end

      it 'buckets the person condition on the distinct id when the group key is usable' do
        # At 60%, `org-flag.user-1` hashes to about 0.48 and `org-flag.acme` to about 0.93.
        c = local_client(org_flag('org-flag', condition(plan_is_pro, rollout_percentage: 60,
                                                                     aggregation_group_type_index: nil)))

        snapshot = c.evaluate_flags('user-1', groups: { organization: 'acme' }, group_properties: { organization: {} },
                                              person_properties: { plan: 'pro' }, only_evaluate_locally: true)

        expect(snapshot.get_flag('org-flag')).to be(true)
      end
    end

    # The server buckets a holdout on the flag-level identifier before any condition. Without a usable
    # group key that identifier is unknown, so a holdout that excludes anyone leaves the flag unresolved.
    describe 'a group flag with a holdout' do
      def holdout_org_flag(exclusion_percentage)
        org_flag.tap do |definition|
          definition[:filters][:holdout] = { id: 727, exclusion_percentage: exclusion_percentage }
        end
      end

      [{}, { organization: '' }].each do |groups|
        context "with groups #{groups.inspect}" do
          it 'is missing_context in local-only mode' do
            c = local_client(holdout_org_flag(50))

            snapshot = c.evaluate_flags('user-1', groups: groups, only_evaluate_locally: true)

            expect(snapshot.get_flag('org-flag')).to be_nil
            expect(snapshot.unresolved_flags).to eq('org-flag' => UnresolvedFlagReason::MISSING_CONTEXT)
            expect(WebMock).not_to have_requested(:post, flags_endpoint)
          end

          it 'falls back to the server with the default getter' do
            c = local_client(holdout_org_flag(50))

            snapshot = c.evaluate_flags('user-1', flag_keys: ['org-flag'], groups: groups)

            expect(snapshot.get_flag('org-flag')).to be(true)
            expect(WebMock).to have_requested(:post, flags_endpoint)
          end

          it 'resolves false locally with a 0% holdout' do
            c = local_client(holdout_org_flag(0))

            snapshot = c.evaluate_flags('user-1', flag_keys: ['org-flag'], groups: groups)

            expect(snapshot.get_flag('org-flag')).to be(false)
            expect(WebMock).not_to have_requested(:post, flags_endpoint)
          end
        end
      end

      it 'buckets the holdout on a usable group key' do
        c = local_client(holdout_org_flag(100))

        snapshot = c.evaluate_flags('user-1', groups: { organization: 'acme' }, only_evaluate_locally: true)

        expect(snapshot.get_flag('org-flag')).to eq('holdout-727')
      end
    end

    describe 'usable group keys' do
      def variant_flag
        org_flag.tap do |definition|
          definition[:filters][:multivariate] = {
            variants: [{ key: 'control', rollout_percentage: 50 }, { key: 'test', rollout_percentage: 50 }]
          }
        end
      end

      { 'a string' => %w[acme acme], 'an integer' => [42, '42'], 'a float' => [4.5, '4.5'] }
        .each do |description, (group_key, rendered_key)|
          it "evaluates and buckets #{description} as its rendered string" do
            c = local_client(variant_flag)

            snapshot = c.evaluate_flags('user-1', groups: { organization: group_key }, only_evaluate_locally: true)
            rendered = c.evaluate_flags('user-1', groups: { organization: rendered_key }, only_evaluate_locally: true)

            expect(snapshot.get_flag('org-flag')).to be_a(String)
            expect(snapshot.get_flag('org-flag')).to eq(rendered.get_flag('org-flag'))
          end
        end

      it 'still evaluates the group condition of a mixed flag' do
        c = local_client(mixed_flag)

        snapshot = c.evaluate_flags('user-1', groups: { organization: 'acme' }, group_properties: { organization: {} },
                                              person_properties: { plan: 'free' }, only_evaluate_locally: true)

        expect(snapshot.get_flag('mixed')).to be(true)
      end

      it 'stays inconclusive without the group properties a condition needs' do
        c = local_client(org_flag('org-flag', condition({ key: 'tier', operator: 'exact', value: 'pro',
                                                          type: 'group', group_type_index: 0 })))

        snapshot = c.evaluate_flags('user-1', groups: { organization: 'acme' }, only_evaluate_locally: true)

        expect(snapshot.unresolved_flags).to eq('org-flag' => UnresolvedFlagReason::MISSING_CONTEXT)
      end
    end
  end
end
