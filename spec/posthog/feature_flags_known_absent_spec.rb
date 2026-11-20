# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe 'known-absent property keys' do
    let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }
    let(:remote_response) do
      { flags: { 'remote-flag' => { key: 'remote-flag', enabled: true, variant: nil, metadata: { id: 9 } } } }
    end

    def flag(key, *properties, **extra)
      { id: 1, key: key, active: true, filters: { groups: [{ properties: properties, rollout_percentage: 100 }] } }
        .merge(extra)
    end

    def person(key, operator, value = nil)
      filter = { key: key, operator: operator, type: 'person' }
      filter[:value] = value unless value.nil?
      filter
    end

    def local_client(*flags, cohorts: {}, group_type_mapping: {})
      stub_request(:get, definitions_endpoint).to_return(
        status: 200, body: { flags: flags, cohorts: cohorts, group_type_mapping: group_type_mapping }.to_json
      )
      stub_request(:post, flags_endpoint).to_return(status: 200, body: remote_response.to_json)
      Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
    end

    def flags_request_body
      body = nil
      expect(WebMock).to(have_requested(:post, flags_endpoint).with { |request| body = JSON.parse(request.body) })
      body
    end

    describe 'operator results for a listed key' do
      {
        ['is_not_set', nil] => true,
        ['is_set', nil] => false,
        %w[exact pro] => false,
        %w[is_not pro] => true,
        %w[icontains pro] => false,
        %w[not_icontains pro] => true,
        %w[starts_with pro] => false,
        %w[not_starts_with pro] => true,
        %w[ends_with pro] => false,
        %w[not_ends_with pro] => true,
        ['regex', '^pro'] => false,
        ['not_regex', '^pro'] => true,
        %w[gt 10] => false,
        %w[gte 10] => false,
        %w[lt 10] => false,
        %w[lte 10] => false,
        ['is_date_before', '2025-01-01T10:00:00Z'] => false,
        ['is_date_after', '2025-01-01T10:00:00Z'] => false,
        ['semver_eq', '1.2.3'] => false,
        ['semver_neq', '1.2.3'] => false,
        ['semver_gt', '1.2.3'] => false,
        ['semver_gte', '1.2.3'] => false,
        ['semver_lt', '1.2.3'] => false,
        ['semver_lte', '1.2.3'] => false,
        ['semver_tilde', '1.2.3'] => false,
        ['semver_caret', '1.2.3'] => false,
        ['semver_wildcard', '1.2.*'] => false
      }.each do |(operator, value), expected|
        it "#{expected ? 'matches' : 'does not match'} #{operator}" do
          property = { key: 'plan', operator: operator, value: value }
          expect(FeatureFlagsPoller.match_property(property, {}, known_absent_keys: Set['plan'])).to be(expected)
        end
      end

      it 'resolves the flag locally without a remote request' do
        c = local_client(flag('incomplete', person('plan', 'is_not_set')), flag('complete', person('plan', 'is_set')))

        snapshot = c.evaluate_flags('user-1', flag_keys: %w[incomplete complete],
                                              person_property_keys_known_absent: ['plan'])

        expect(snapshot.get_flag('incomplete')).to be(true)
        expect(snapshot.get_flag('complete')).to be(false)
        expect(WebMock).not_to have_requested(:post, flags_endpoint)
      end
    end

    it 'overrides a supplied value for a listed key' do
      c = local_client(flag('incomplete', person('plan', 'is_not_set')))

      snapshot = c.evaluate_flags('user-1', flag_keys: ['incomplete'], person_properties: { plan: 'pro' },
                                            person_property_keys_known_absent: [:plan])

      expect(snapshot.get_flag('incomplete')).to be(true)
      expect(WebMock).not_to have_requested(:post, flags_endpoint)
    end

    it 'overrides the distinct_id the SDK adds to person properties' do
      c = local_client(flag('no-distinct-id', person('distinct_id', 'is_not_set')))

      snapshot = c.evaluate_flags('user-1', flag_keys: ['no-distinct-id'], only_evaluate_locally: true,
                                            person_property_keys_known_absent: ['distinct_id'])

      expect(snapshot.get_flag('no-distinct-id')).to be(true)
    end

    it 'keeps an omitted key that is not listed inconclusive' do
      c = local_client(flag('incomplete', person('plan', 'is_not_set')))

      snapshot = c.evaluate_flags('user-1', flag_keys: ['incomplete'], only_evaluate_locally: true,
                                            person_property_keys_known_absent: ['region'])

      expect(snapshot.unresolved_flags).to eq('incomplete' => UnresolvedFlagReason::MISSING_CONTEXT)
    end

    it 'ignores person keys with the person-metadata prefix' do
      key = '__posthog_person_metadata__created_at'
      c = local_client(flag('old-account', person(key, 'is_date_before', '2025-01-01T00:00:00Z')))

      snapshot = c.evaluate_flags('user-1', flag_keys: ['old-account'], only_evaluate_locally: true,
                                            person_properties: { key => '2024-01-01T00:00:00Z' },
                                            person_property_keys_known_absent: [key])

      expect(snapshot.get_flag('old-account')).to be(true)
    end

    it 'still sends a person-metadata key to /flags as provided' do
      known_absent = KnownAbsentPropertyKeys.build(%w[__posthog_person_metadata__created_at plan], nil)

      expect(known_absent.person_keys).to eq(Set['plan'])
      expect(known_absent.request_fields).to eq(
        person_property_keys_known_absent: %w[__posthog_person_metadata__created_at plan]
      )
    end

    describe 'group keys' do
      let(:org_tier_not_set) do
        flag('org-incomplete', { key: 'tier', operator: 'is_not_set', type: 'group', group_type_index: 0 })
          .tap { |definition| definition[:filters][:aggregation_group_type_index] = 0 }
      end

      def group_client(definition)
        local_client(definition, group_type_mapping: { '0' => 'organization', '1' => 'project' })
      end

      it 'apply to their own group type' do
        c = group_client(org_tier_not_set)

        snapshot = c.evaluate_flags('user-1', flag_keys: ['org-incomplete'], groups: { organization: 'acme' },
                                              group_property_keys_known_absent: { organization: ['tier'] })

        expect(snapshot.get_flag('org-incomplete')).to be(true)
        expect(WebMock).not_to have_requested(:post, flags_endpoint)
      end

      it 'do not apply to another group type' do
        c = group_client(org_tier_not_set)

        snapshot = c.evaluate_flags('user-1', flag_keys: ['org-incomplete'], groups: { organization: 'acme' },
                                              only_evaluate_locally: true,
                                              group_property_keys_known_absent: { 'project' => ['tier'] })

        expect(snapshot.unresolved_flags).to eq('org-incomplete' => UnresolvedFlagReason::MISSING_CONTEXT)
      end

      it 'do not apply to person properties' do
        c = local_client(flag('incomplete', person('tier', 'is_not_set')))

        snapshot = c.evaluate_flags('user-1', flag_keys: ['incomplete'], only_evaluate_locally: true,
                                              group_property_keys_known_absent: { organization: ['tier'] })

        expect(snapshot.unresolved_flags).to eq('incomplete' => UnresolvedFlagReason::MISSING_CONTEXT)
      end

      it 'override the $group_key the SDK adds to group properties' do
        definition = flag('no-group-key', { key: '$group_key', operator: 'is_not_set', type: 'group' })
        definition[:filters][:aggregation_group_type_index] = 0
        c = group_client(definition)

        snapshot = c.evaluate_flags('user-1', flag_keys: ['no-group-key'], groups: { organization: 'acme' },
                                              only_evaluate_locally: true,
                                              group_property_keys_known_absent: { organization: ['$group_key'] })

        expect(snapshot.get_flag('no-group-key')).to be(true)
      end

      it 'apply to a group condition in a mixed-targeting flag' do
        definition = flag('mixed')
        definition[:filters][:groups] = [{
          properties: [{ key: 'tier', operator: 'is_not_set', type: 'group', group_type_index: 1 }],
          rollout_percentage: 100, aggregation_group_type_index: 1
        }]
        c = group_client(definition)

        snapshot = c.evaluate_flags('user-1', flag_keys: ['mixed'], groups: { project: 'p1' },
                                              only_evaluate_locally: true,
                                              group_property_keys_known_absent: { project: ['tier'] })

        expect(snapshot.get_flag('mixed')).to be(true)
      end
    end

    describe 'filters local evaluation cannot use' do
      [
        ['not_icontains_multi', ['pro']],
        ['not_between', [1, 2]],
        ['future_operator', 'pro'],
        %w[gt not-a-number],
        ['not_regex', '(?=pro)']
      ].each do |operator, value|
        it "stays unsupported for #{operator} #{value.inspect} on a listed key" do
          property = { key: 'plan', operator: operator, value: value }
          expect do
            FeatureFlagsPoller.match_property(property, {}, known_absent_keys: Set['plan'])
          end.to raise_error(InconclusiveMatchError) { |e|
            expect(e.reason).to eq(UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
          }
        end
      end

      it 'fall back to /flags with the listed keys' do
        c = local_client(flag('multi', person('plan', 'not_icontains_multi', ['pro'])))
        stub_request(:post, flags_endpoint).to_return(
          status: 200,
          body: { flags: { 'multi' => { key: 'multi', enabled: true, variant: nil, metadata: { id: 1 } } } }.to_json
        )

        snapshot = c.evaluate_flags('user-1', flag_keys: ['multi'], person_property_keys_known_absent: ['plan'])

        expect(snapshot.get_flag('multi')).to be(true)
        expect(flags_request_body['person_property_keys_known_absent']).to eq(['plan'])
      end
    end

    describe 'dynamic cohorts' do
      let(:cohorts) do
        {
          '7' => { type: 'AND', values: [{ type: 'AND', values: [
            { key: 'plan', operator: 'is_set', type: 'person', negation: true }
          ] }] }
        }
      end

      it 'apply negation after the known-absent result' do
        c = local_client(flag('no-plan-cohort', { key: 'id', value: 7, type: 'cohort' }), cohorts: cohorts)

        snapshot = c.evaluate_flags('user-1', flag_keys: ['no-plan-cohort'], only_evaluate_locally: true,
                                              person_property_keys_known_absent: ['plan'])

        expect(snapshot.get_flag('no-plan-cohort')).to be(true)
      end

      [false, true].each do |negation|
        it "check operator support before the known-absent table with negation #{negation}" do
          range_cohorts = {
            '8' => { type: 'AND', values: [{ type: 'AND', values: [
              { key: 'plan', operator: 'not_between', value: [1, 2], type: 'person', negation: negation }
            ] }] }
          }
          c = local_client(flag('range-cohort', { key: 'id', value: 8, type: 'cohort' }), cohorts: range_cohorts)
          stub_request(:post, flags_endpoint).to_return(
            status: 200,
            body: { flags: { 'range-cohort' => { key: 'range-cohort', enabled: true, variant: nil,
                                                 metadata: { id: 1 } } } }.to_json
          )

          local = c.evaluate_flags('user-1', flag_keys: ['range-cohort'], only_evaluate_locally: true,
                                             person_property_keys_known_absent: ['plan'])
          expect(local.get_flag('range-cohort')).to be_nil
          expect(local.unresolved_flags).to eq('range-cohort' => UnresolvedFlagReason::UNSUPPORTED_DEFINITION)

          remote = c.evaluate_flags('user-1', flag_keys: ['range-cohort'],
                                              person_property_keys_known_absent: ['plan'])
          expect(remote.get_flag('range-cohort')).to be(true)
          expect(flags_request_body['person_property_keys_known_absent']).to eq(['plan'])
        end
      end
    end

    it 'applies to flag dependencies' do
      dependency = { key: 'incomplete', type: 'flag', value: true, operator: 'flag_evaluates_to',
                     dependency_chain: ['incomplete'] }
      c = local_client(flag('incomplete', person('plan', 'is_not_set')), flag('dependent', dependency))

      snapshot = c.evaluate_flags('user-1', flag_keys: ['dependent'], only_evaluate_locally: true,
                                            person_property_keys_known_absent: ['plan'])

      expect(snapshot.get_flag('dependent')).to be(true)
    end

    describe 'the /flags request body' do
      let(:inconclusive_flag) { flag('needs-region', person('region', 'exact', 'eu')) }

      it 'includes the listed person and group keys on fallback' do
        c = local_client(inconclusive_flag)

        c.evaluate_flags('user-1', groups: { organization: 'acme' },
                                   person_property_keys_known_absent: ['plan'],
                                   group_property_keys_known_absent: { organization: ['tier'] })

        body = flags_request_body
        expect(body['person_property_keys_known_absent']).to eq(['plan'])
        expect(body['group_property_keys_known_absent']).to eq('organization' => ['tier'])
      end

      it 'omits the fields when nothing was provided' do
        c = local_client(inconclusive_flag)

        c.evaluate_flags('user-1')

        body = flags_request_body
        expect(body).not_to have_key('person_property_keys_known_absent')
        expect(body).not_to have_key('group_property_keys_known_absent')
      end

      it 'omits empty fields' do
        c = local_client(inconclusive_flag)

        c.evaluate_flags('user-1', person_property_keys_known_absent: [],
                                   group_property_keys_known_absent: { organization: [] })

        body = flags_request_body
        expect(body).not_to have_key('person_property_keys_known_absent')
        expect(body).not_to have_key('group_property_keys_known_absent')
      end

      it 'includes the listed keys for the legacy single-flag getter' do
        c = local_client(inconclusive_flag)
        allow(Kernel).to receive(:warn)

        c.get_feature_flag_result('needs-region', 'user-1', person_property_keys_known_absent: ['plan'])

        expect(flags_request_body['person_property_keys_known_absent']).to eq(['plan'])
      end

      it 'includes the listed keys for all flags and payloads' do
        c = local_client(inconclusive_flag)

        c.get_all_flags_and_payloads('user-1', group_property_keys_known_absent: { organization: ['tier'] })

        expect(flags_request_body['group_property_keys_known_absent']).to eq('organization' => ['tier'])
      end

      it 'includes the listed keys for send_feature_flags on capture' do
        c = local_client(inconclusive_flag)
        allow(Kernel).to receive(:warn)

        c.capture(distinct_id: 'user-1', event: 'signed_up',
                  send_feature_flags: { person_property_keys_known_absent: ['plan'] })

        expect(flags_request_body['person_property_keys_known_absent']).to eq(['plan'])
      end

      it 'includes the listed keys for a SendFeatureFlagsOptions object on capture' do
        c = local_client(inconclusive_flag)
        allow(Kernel).to receive(:warn)
        options = SendFeatureFlagsOptions.new(group_property_keys_known_absent: { organization: ['tier'] })

        c.capture(distinct_id: 'user-1', event: 'signed_up', send_feature_flags: options)

        expect(flags_request_body['group_property_keys_known_absent']).to eq('organization' => ['tier'])
      end
    end

    describe 'limits' do
      let(:too_many) { Array.new(KnownAbsentPropertyKeys::MAX_KEYS + 1, 'plan') }

      it 'accepts 1000 keys' do
        c = local_client(flag('needs-region', person('region', 'exact', 'eu')))

        c.evaluate_flags('user-1', person_property_keys_known_absent: Array.new(1000) { |i| "key-#{i}" })

        expect(flags_request_body['person_property_keys_known_absent'].length).to eq(1000)
      end

      it 'rejects more than 1000 person keys, counting duplicates, without a request' do
        c = local_client(flag('needs-region', person('region', 'exact', 'eu')))

        expect do
          c.evaluate_flags('user-1', person_property_keys_known_absent: too_many)
        end.to raise_error(ArgumentError, /person_property_keys_known_absent allows at most 1000 keys/)
        expect(WebMock).not_to have_requested(:post, flags_endpoint)
      end

      it 'rejects more than 1000 person keys for an empty flag scope' do
        c = local_client(flag('needs-region', person('region', 'exact', 'eu')))

        expect do
          c.evaluate_flags('user-1', flag_keys: [], person_property_keys_known_absent: too_many)
        end.to raise_error(ArgumentError, /person_property_keys_known_absent allows at most 1000 keys/)
      end

      it 'rejects more than 1000 keys for one group type' do
        c = local_client(flag('needs-region', person('region', 'exact', 'eu')))

        expect do
          c.get_all_flags('user-1', group_property_keys_known_absent: { organization: too_many })
        end.to raise_error(ArgumentError, /group_property_keys_known_absent\[organization\] allows at most 1000/)
        expect(WebMock).not_to have_requested(:post, flags_endpoint)
      end

      it 'counts group keys per group type' do
        known_absent = KnownAbsentPropertyKeys.build(
          nil, { organization: Array.new(1000, 'tier'), project: Array.new(1000, 'tier') }
        )

        expect(known_absent.group_keys(:project)).to eq(Set['tier'])
      end

      it 'merges String and Symbol names for the same group type before the limit check' do
        known_absent = KnownAbsentPropertyKeys.build(nil, { organization: ['tier'], 'organization' => ['region'] })

        expect(known_absent.group_keys(:organization)).to eq(Set['tier', 'region'])
        expect(known_absent.request_fields)
          .to eq(group_property_keys_known_absent: { 'organization' => %w[tier region] })
        too_many = { organization: Array.new(600, 'tier'), 'organization' => Array.new(401, 'region') }
        expect { KnownAbsentPropertyKeys.build(nil, too_many) }
          .to raise_error(ArgumentError, /allows at most 1000 keys, got 1001/)
      end

      it 'rejects inputs of the wrong type' do
        expect { KnownAbsentPropertyKeys.build('plan', nil) }.to raise_error(ArgumentError)
        expect { KnownAbsentPropertyKeys.build(nil, ['tier']) }.to raise_error(ArgumentError)
        expect { KnownAbsentPropertyKeys.build([1], nil) }.to raise_error(ArgumentError)
        expect { KnownAbsentPropertyKeys.build(nil, { 1 => ['tier'] }) }.to raise_error(ArgumentError)
      end
    end
  end
end
