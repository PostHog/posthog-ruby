# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PostHog::FeatureFlagsPoller, 'property matching versions' do
  rows = [
    [false, 'banana', true, false],
    [false, 0, true, false],
    [%w[true false], 'true', false, true],
    [%w[true false], 'pro', true, false],
    [[], true, true, true],
    [[], [], true, true],
    [true, [true], true, false],
    [false, 'FALSE', true, true],
    [false, nil, true, false],
    [false, {}, true, false],
    [[], [true, 'TRUE', []], true, true],
    [[], [true, 0], false, false],
    [[], false, false, false],
    [[], 0, false, false],
    [[], 'banana', false, false],
    [false, '', true, false],
    ['null', nil, true, true],
    [nil, nil, true, true],
    ['', nil, false, false],
    [[nil, 'PRO'], 'null', true, true],
    [[true, 'PRO'], 'TRUE', true, true],
    [[1, 'PRO'], '1', true, true],
    [[[true, true], 'PRO'], [true, true], true, true],
    ['[true,true]', [true, true], true, true],
    ['{"a":null,"b":[true,{"c":false}]}', { b: [true, { c: false }], a: nil }, true, true],
    ['ÄBC', 'äbc', true, true]
  ]

  [nil, 0, 1, 2, 3, '2'].each do |version|
    rows.each do |filter, value, legacy, explicit|
      %w[exact is_not].each do |operator|
        it "matches #{filter.inspect} against #{value.inspect} with #{operator}, version #{version.inspect}" do
          expected = version == 2 ? explicit : legacy
          expected = !expected if operator == 'is_not'
          expect(described_class.match_property(
                   { key: 'value', value: filter, operator: operator }, { value: value }, {},
                   property_matching_version: version
                 )).to eq(expected)
        end
      end
    end

    it "keeps missing properties inconclusive for version #{version.inspect}" do
      %w[exact is_not].each do |operator|
        expect do
          described_class.match_property({ key: 'value', value: false, operator: operator }, {}, {},
                                         property_matching_version: version)
        end.to raise_error(PostHog::InconclusiveMatchError)
      end
    end
  end

  it 'defaults public matching helpers to service legacy semantics' do
    expect(described_class.match_property({ key: 'value', value: false }, { value: 'banana' })).to be(true)
  end

  let(:url) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
  let(:leaf) { { key: 'value', value: false, operator: 'exact', type: 'person' } }
  let(:definitions) do
    {
      flags: [
        flag('person', [leaf]),
        flag('group', [leaf], aggregation_group_type_index: 0),
        flag('mixed', [leaf]).tap { |f| f[:filters][:groups][0][:aggregation_group_type_index] = 0 },
        flag('cohort', [{ key: 'id', value: 1, type: 'cohort' }]),
        flag('dependency', [{ key: 'person', value: true, operator: 'flag_evaluates_to', type: 'flag',
                              dependency_chain: ['person'] }])
      ],
      group_type_mapping: { '0' => 'company' },
      cohorts: { '1' => { type: 'AND', values: [{ type: 'OR', values: [leaf] }] } }
    }
  end

  def flag(key, properties, **filters)
    { key: key, active: true, version: 2, filters: { groups: [{ properties: properties }] }.merge(filters) }
  end

  def local_flags(poller)
    poller.get_all_flags_and_payloads('person-id', { company: 'company-id' }, { value: 'banana' },
                                      { company: { value: 'banana' } }, true)[:featureFlags]
  end

  def expect_local_flags(poller, expected)
    expect(local_flags(poller)).to eq(definitions[:flags].to_h { |f| [f[:key], expected] })
    definitions[:flags].each do |f|
      result = poller.get_feature_flag(f[:key], 'person-id', { company: 'company-id' }, { value: 'banana' },
                                       { company: { value: 'banana' } }, true)
      expect(result[0..1]).to eq([expected, true])
    end
  end

  let(:poller) { described_class.new(60, nil, API_KEY, 'https://us.i.posthog.com', 3) }

  after { poller.shutdown_poller }

  it 'propagates version-only reloads to person, group, mixed, recursive cohort and dependency evaluations' do
    %w[exact is_not].each do |operator|
      leaf[:operator] = operator
      [1, 2, 1, 2, nil, 3].each do |version|
        data = definitions.merge(property_matching_version: version)
        data.delete(:property_matching_version) if version.nil?
        poller._apply_flag_definitions(data)
        expect_local_flags(poller, operator == 'exact' ? version != 2 : version == 2)
      end
    end
    expect(WebMock).not_to have_requested(:post, %r{/flags/})
  end

  it 'uses one snapshot in the full-result API and observes version-only reloads on the next call' do
    client = PostHog::Client.new(api_key: API_KEY, test_mode: true)
    client_poller = client.instance_variable_get(:@feature_flags_poller)
    options = { groups: { company: 'company-id' }, person_properties: { value: 'banana' },
                group_properties: { company: { value: 'banana' } }, only_evaluate_locally: true }
    client_poller._apply_flag_definitions(definitions.merge(property_matching_version: 1))
    refreshed = false
    allow(client_poller).to receive(:_compute_flag_locally).and_wrap_original do |original, *args, **kwargs|
      unless refreshed
        refreshed = true
        client_poller._apply_flag_definitions(definitions.merge(property_matching_version: 2))
      end
      original.call(*args, **kwargs)
    end
    first = client.evaluate_flags('person-id', **options)
    second = client.evaluate_flags('person-id', **options)
    client_poller._apply_flag_definitions(definitions.merge(property_matching_version: 1))
    third = client.evaluate_flags('person-id', **options)
    definitions[:flags].each do |f|
      expect([first.get_flag(f[:key]), second.get_flag(f[:key]), third.get_flag(f[:key])]).to eq([true, false, true])
    end
    expect(WebMock).not_to have_requested(:post, %r{/flags/})
  ensure
    client&.shutdown
  end

  it 'preserves the evaluation snapshot when definitions refresh during a dependency evaluation' do
    poller._apply_flag_definitions(definitions.merge(property_matching_version: 1))
    allow(poller).to receive(:evaluate_flag_dependency).and_wrap_original do |original, *args, **kwargs|
      poller._apply_flag_definitions(definitions.merge(property_matching_version: 2))
      original.call(*args, **kwargs)
    end
    result = poller.get_feature_flag('dependency', 'person-id', {}, { value: 'banana' }, {}, true)
    expect(result[0..1]).to eq([true, true])
    expect(local_flags(poller).values).to all(be(false))
  end

  it 'retains the matching snapshot for payload lookup during a refresh' do
    data = definitions.merge(property_matching_version: 1)
    data[:flags][0][:filters][:payloads] = { 'true' => 'old-payload' }
    poller._apply_flag_definitions(data)
    allow(poller).to receive(:_compute_flag_payload_locally).and_wrap_original do |original, *args, **kwargs|
      data[:flags][0][:filters][:payloads] = { 'true' => 'new-payload' }
      poller._apply_flag_definitions(data.merge(property_matching_version: 2))
      original.call(*args, **kwargs)
    end
    expect(poller.get_feature_flag_payload('person', 'person-id', nil, {}, { value: 'banana' }, {}, true))
      .to eq('old-payload')
  end

  it 'captures the empty initial snapshot when the first load publishes immediately after the atomic read' do
    reference = poller.instance_variable_get(:@definition_snapshot)
    published = false
    allow(reference).to receive(:value).and_wrap_original do |original|
      snapshot = original.call
      unless published
        published = true
        # Deterministically schedule first-load publication between the read and its caller resuming.
        poller._apply_flag_definitions(definitions.merge(property_matching_version: 2))
      end
      snapshot
    end

    expect(local_flags(poller)).to eq({})
    expect_local_flags(poller, false)
    expect(WebMock).not_to have_requested(:post, %r{/flags/})
  end

  it 'loads matching versions on the asynchronous poller and observes an omitted version on reload' do
    stub_request(:get, url).to_return(status: 200, body: definitions.merge(property_matching_version: 2).to_json)
    async_poller = described_class.new(60, API_KEY, API_KEY, 'https://us.i.posthog.com', 3, async_load: true)
    eventually { expect(async_poller.definitions_loaded?).to be(true) }
    expect_local_flags(async_poller, false)
    stub_request(:get, url).to_return(status: 200, body: definitions.to_json)
    async_poller.load_feature_flags(true)
    expect_local_flags(async_poller, true)
  ensure
    async_poller&.shutdown_poller
  end

  it 'keeps version and definitions across 304 and failures, resetting an omitted version on fresh responses' do
    stub_request(:get, url).to_return(
      { status: 200, body: definitions.merge(property_matching_version: 2).to_json, headers: { 'ETag' => 'v2' } },
      { status: 304 },
      { status: 500, body: '{}' },
      { status: 200, body: 'invalid json' },
      { status: 200, body: definitions.to_json }
    )
    poller._load_feature_flags
    expect_local_flags(poller, false)
    poller._load_feature_flags
    expect_local_flags(poller, false)
    poller._load_feature_flags
    expect_local_flags(poller, false)
    poller._load_feature_flags
    expect_local_flags(poller, false)
    poller._load_feature_flags
    expect_local_flags(poller, true)
  end

  it 'round trips version through JSON external caches and defaults older entries to legacy' do
    provider = double('cache', should_fetch_flag_definitions?: true, shutdown: nil)
    allow(provider).to receive(:flag_definitions)
    stored = nil
    allow(provider).to receive(:on_flag_definitions_received) { |data| stored = JSON.parse(JSON.generate(data)) }
    poller.instance_variable_set(:@flag_definition_cache_provider, provider)
    cached_poller = described_class.new(60, nil, API_KEY, 'https://us.i.posthog.com', 3)
    cached_poller.instance_variable_set(:@flag_definition_cache_provider, provider)
    allow(provider).to receive(:flag_definitions) { stored }

    [1, 2, 1, 2].each do |version|
      allow(provider).to receive(:should_fetch_flag_definitions?).and_return(true)
      stub_request(:get, url).to_return(
        status: 200, body: definitions.merge(property_matching_version: version).to_json
      )
      poller._load_feature_flags
      expect(stored['property_matching_version']).to eq(version)
      allow(provider).to receive(:should_fetch_flag_definitions?).and_return(false)
      cached_poller._load_feature_flags
      expect_local_flags(cached_poller, version != 2)
    end

    stored.delete('property_matching_version')
    cached_poller._load_feature_flags
    expect_local_flags(cached_poller, true)
  ensure
    cached_poller&.shutdown_poller
  end
end
