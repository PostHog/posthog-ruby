# frozen_string_literal: true

require 'spec_helper'

# A cohort can filter on Person metadata > First seen (type "person_metadata", key "created_at").
# The flags service reads that value from the persons table and ignores a created_at person property,
# so local evaluation must not match it, or any other filter type it doesn't know, against one.
# Mirrors the "Unsupported property-filter types are inconclusive" requirement of the local evaluator spec.
module PostHog
  describe FeatureFlagsPoller, 'unsupported property-filter types' do
    let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
    let(:client) { Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }
    let(:first_seen) { { key: 'created_at', type: 'person_metadata', operator: 'is_date_after', value: '2025-01-01' } }
    let(:plan_is_pro) { { key: 'plan', type: 'person', operator: 'exact', value: 'pro' } }
    let(:in_cohort) { { key: 'id', type: 'cohort', value: 7 } }

    before do
      stub_request(:get, definitions_endpoint).to_return(status: 200, body: { flags: [] }.to_json)
    end

    after { client.shutdown }

    def flag(key, *conditions, **filters)
      { id: 1, key: key, active: true, filters: { groups: conditions }.merge(filters) }
    end

    def condition(*properties, rollout_percentage: 100, **extra)
      { properties: properties, rollout_percentage: rollout_percentage }.merge(extra)
    end

    def cohort(*leaves, group_type: 'AND')
      { '7' => { type: group_type, values: leaves } }
    end

    def evaluate(definition, properties, flags: [], cohorts: {})
      poller._apply_flag_definitions(flags: [definition, *flags], group_type_mapping: {}, cohorts: cohorts)
      snapshot = poller._evaluation_snapshot
      poller.match_feature_flag_properties(snapshot[:flags_by_key][definition[:key]], 'user-123', properties, {},
                                           snapshot[:cohorts])
    end

    def expect_unsupported_definition(&block)
      expect(&block).to raise_error(InconclusiveMatchError) do |error|
        expect(error).not_to be_a(RequiresServerEvaluation)
        expect(error.reason).to eq(UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      end
    end

    {
      'type person' => { type: 'person' },
      'the type field omitted' => {},
      'a null type' => { type: nil },
      'an empty-string type' => { type: '' }
    }.each do |description, type_state|
      it "matches a filter with #{description} against caller properties" do
        filter = { key: 'created_at', operator: 'is_date_after', value: '2025-01-01' }.merge(type_state)

        expect(evaluate(flag('created-person-prop', condition(filter)), { created_at: '2026-06-01' })).to be(true)
      end
    end

    it 'matches a group filter against caller properties' do
      filter = { key: 'plan', type: 'group', group_type_index: 0, operator: 'exact', value: 'pro' }

      expect(FeatureFlagsPoller.match_property(filter, { plan: 'pro' })).to be(true)
    end

    {
      'created in 2026' => { created_at: '2026-06-01' },
      'created in 2020' => { created_at: '2020-06-01' },
      'without person properties' => {}
    }.each do |description, properties|
      it "is inconclusive for a person_metadata cohort leaf #{description}" do
        expect_unsupported_definition do
          evaluate(flag('first-seen', condition(in_cohort)), properties, cohorts: cohort(first_seen))
        end
      end

      it "is inconclusive for a person_metadata condition filter #{description}" do
        expect_unsupported_definition { evaluate(flag('first-seen', condition(first_seen)), properties) }
      end
    end

    it 'does not let leaf negation turn an unsupported cohort leaf into a match' do
      expect_unsupported_definition do
        evaluate(flag('first-seen', condition(in_cohort)), { created_at: '2020-06-01' },
                 cohorts: cohort(first_seen.merge(negation: true)))
      end
    end

    it 'does not let a not_in cohort operator turn an unsupported cohort leaf into a match' do
      expect_unsupported_definition do
        evaluate(flag('first-seen', condition(in_cohort.merge(operator: 'not_in'))), { created_at: '2020-06-01' },
                 cohorts: cohort(first_seen))
      end
    end

    it 'lets another cohort leaf decide an AND group' do
      definition = flag('first-seen-pro', condition(in_cohort))

      expect(evaluate(definition, { plan: 'free' }, cohorts: cohort(first_seen, plan_is_pro))).to be(false)
    end

    it 'lets another cohort leaf decide an OR group' do
      definition = flag('first-seen-pro', condition(in_cohort))

      expect(evaluate(definition, { plan: 'pro' }, cohorts: cohort(first_seen, plan_is_pro, group_type: 'OR')))
        .to be(true)
    end

    it 'lets a definitively false filter decide a condition with an unsupported filter' do
      region = { key: 'region', type: 'future_type', operator: 'exact', value: 'eu' }

      expect(evaluate(flag('future-type-plan', condition(region, plan_is_pro)), { plan: 'free', region: 'eu' }))
        .to be(false)
    end

    [true, false].each do |early_exit|
      it "lets a later condition decide the flag with early_exit #{early_exit}" do
        definition = flag('first-seen', condition(first_seen, variant: 'new-user'),
                          condition(variant: 'existing-user'),
                          early_exit: early_exit,
                          multivariate: { variants: [{ key: 'new-user', rollout_percentage: 50 },
                                                     { key: 'existing-user', rollout_percentage: 50 }] })

        expect(evaluate(definition, { created_at: '2026-06-01' })).to eq('existing-user')
      end
    end

    it 'defers only the flag with an unrecognized filter type' do
      future_type = { key: 'plan', type: 'future_type', operator: 'exact', value: 'pro' }
      stub_request(:get, definitions_endpoint).to_return(
        status: 200, body: { flags: [flag('future-type', condition(future_type)), flag('beta-ui', condition)] }.to_json
      )

      snapshot = client.evaluate_flags('user-123', person_properties: { plan: 'pro' }, only_evaluate_locally: true)

      expect(snapshot.keys).not_to include('future-type')
      expect(snapshot.unresolved_flags).to eq('future-type' => UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
      expect(snapshot.get_flag('beta-ui')).to be(true)
    end

    it 'falls back to the flags service for a person_metadata cohort leaf' do
      stub_request(:get, definitions_endpoint).to_return(
        status: 200, body: { flags: [flag('first-seen', condition(in_cohort))], cohorts: cohort(first_seen) }.to_json
      )
      # The person was created in 2020, so the flags service answers false.
      stub_request(:post, 'https://us.i.posthog.com/flags/?v=2').to_return(
        status: 200, body: { flags: { 'first-seen' => { key: 'first-seen', enabled: false, variant: nil } } }.to_json
      )

      snapshot = client.evaluate_flags('user-123', person_properties: { created_at: '2026-06-01' },
                                                   flag_keys: ['first-seen'])

      expect(snapshot.get_flag('first-seen')).to be(false)
      expect(WebMock).to have_requested(:post, 'https://us.i.posthog.com/flags/?v=2').once
    end

    describe '.definition_unresolved_reason' do
      {
        'a person_metadata condition filter' => -> { first_seen },
        'a person_metadata cohort leaf' => -> { in_cohort },
        'an unrecognized filter type' => -> { { key: 'plan', type: 'future_type', operator: 'exact', value: 'pro' } }
      }.each do |description, build_filter|
        it "returns unsupported_definition for #{description}" do
          checkout = flag('checkout', condition(instance_exec(&build_filter)))

          reason = FeatureFlagsPoller.definition_unresolved_reason(checkout, { 'checkout' => checkout },
                                                                   cohort(first_seen), {})

          expect(reason).to eq(UnresolvedFlagReason::UNSUPPORTED_DEFINITION)
        end
      end

      [{ type: 'person' }, {}, { type: nil }, { type: '' }, { type: 'group', group_type_index: 0 }].each do |type_state|
        it "returns nil for a filter with #{type_state.inspect}" do
          checkout = flag('checkout', condition(plan_is_pro.except(:type).merge(type_state)))

          expect(FeatureFlagsPoller.definition_unresolved_reason(checkout, { 'checkout' => checkout }, {}, {}))
            .to be_nil
        end
      end
    end
  end
end
