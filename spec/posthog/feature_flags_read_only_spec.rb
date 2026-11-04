# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PostHog::FeatureFlagsPoller do
  describe '.match_property' do
    it 'reuses a symbol-keyed filter without changing it' do
      property = { key: 'plan', operator: 'exact', value: 'pro' }.freeze
      properties = { plan: 'pro' }.freeze
      expect(described_class).to receive(:match_property_value).with(be(property), be(properties), 1).and_call_original

      expect(described_class.match_property(property, properties)).to be(true)
    end

    [
      { 'key' => 'plan', 'operator' => 'exact', 'value' => 'pro' },
      { 'key' => 'plan', operator: 'exact', value: 'pro' }
    ].each do |filter|
      it "matches a read-only filter with keys #{filter.keys.inspect}" do
        property = filter.freeze

        expect(described_class.match_property(property, { 'plan' => 'pro' }.freeze)).to be(true)
        expect(described_class.match_property(property, { 'plan' => 'free' }.freeze)).to be(false)
      end
    end
  end

  describe '.match_property_group' do
    [
      { key: 'country', operator: 'exact', value: 'US', negation: true },
      { 'key' => 'country', 'operator' => 'exact', 'value' => 'US', 'negation' => true }
    ].each do |filter|
      it "evaluates a read-only negated cohort filter with keys #{filter.keys.inspect}" do
        group = { type: 'AND', values: [filter.freeze] }

        expect(described_class.match_property_group(group, { country: 'CA' }, {})).to be(true)
        expect(described_class.match_property_group(group, { country: 'US' }, {})).to be(false)
      end
    end
  end

  it 'evaluates cached flag and cohort filters concurrently without changing the definitions' do
    definitions = {
      flags: [
        {
          key: 'property-flag', active: true,
          filters: { groups: [{ properties: [{ key: 'plan', value: 'pro', operator: 'exact' }] }] }
        },
        {
          key: 'cohort-flag', active: true,
          filters: { groups: [{ properties: [{ type: 'cohort', value: 1 }] }] }
        }
      ],
      cohorts: {
        '1' => { type: 'AND', values: [{ key: 'country', value: 'US', operator: 'exact', negation: true }] }
      }
    }
    stub_request(:get, 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true')
      .to_return(status: 200, body: definitions.to_json)
    errors = Queue.new
    client = PostHog::Client.new(
      api_key: API_KEY, secret_key: API_KEY, test_mode: true,
      feature_flags_polling_interval: 3600, on_error: ->(*error) { errors << error }
    )
    poller = client.instance_variable_get(:@feature_flags_poller)
    snapshot = poller._evaluation_snapshot
    filters = snapshot[:flags].flat_map { |flag| flag[:filters][:groups].flat_map { |group| group[:properties] } }
    filters.concat(snapshot[:cohorts].values.flat_map { |cohort| cohort[:values] })
    filters.each(&:freeze)
    before = JSON.generate([snapshot[:flags].to_a, snapshot[:cohorts].to_h])

    properties = { 'plan' => 'pro', 'country' => 'CA', 'distinct_id' => 'explicit-user' }.freeze
    groups = { 'company' => 'acme' }.freeze
    group_properties = { 'company' => { 'region' => 'US' }.freeze }.freeze
    results = Array.new(8) do
      Thread.new do
        Array.new(20) do
          client.get_all_flags(
            'benchmark-user', person_properties: properties, groups: groups,
                              group_properties: group_properties, only_evaluate_locally: true
          )
        end
      end
    end.flat_map(&:value)

    expect(results).to all(eq('property-flag' => true, 'cohort-flag' => true))
    expect(errors).to be_empty
    expect(JSON.generate([snapshot[:flags].to_a, snapshot[:cohorts].to_h])).to eq(before)
    expect(poller._evaluation_snapshot).to equal(snapshot)
    assert_not_requested :post, 'https://us.i.posthog.com/flags/?v=2'
  ensure
    client&.shutdown
  end
end
