# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Feature flag evaluation inputs' do
  let(:definitions_endpoint) { 'https://us.i.posthog.com/flags/definitions?token=testsecret&send_cohorts=true' }
  let(:flags_endpoint) { 'https://us.i.posthog.com/flags/?v=2' }
  let(:groups) { { 'company' => 'acme' }.freeze }
  let(:person_properties) { { 'plan' => 'pro', 'distinct_id' => 'explicit-user' }.freeze }
  let(:group_properties) { { 'company' => { 'region' => 'US' }.freeze }.freeze }
  let(:options) do
    { groups: groups, person_properties: person_properties, group_properties: group_properties,
      only_evaluate_locally: true }
  end
  let(:client) { PostHog::Client.new(api_key: API_KEY, secret_key: API_KEY, test_mode: true) }
  let(:definitions) do
    {
      flags: [
        { key: 'person-flag', active: true,
          filters: { groups: [{ properties: [{ key: 'plan', value: 'pro' }] }] } },
        { key: 'group-flag', active: true,
          filters: { aggregation_group_type_index: 0,
                     groups: [{ properties: [{ key: 'region', value: 'US' }] }],
                     payloads: { 'true' => '{"source":"local"}' } } }
      ],
      group_type_mapping: { '0' => 'company' }
    }
  end

  before do
    stub_request(:get, definitions_endpoint).to_return(status: 200, body: definitions.to_json)
    stub_request(:post, flags_endpoint)
      .to_return(status: 200, body: { featureFlags: { 'person-flag' => true, 'group-flag' => true } }.to_json)
    stub_request(:post, 'https://us.i.posthog.com/batch/').to_return(status: 200, body: '{"status":1}')
  end

  after do
    client.shutdown
  end

  %i[evaluate_flags get_all_flags get_all_flags_and_payloads get_feature_flag
     get_feature_flag_result is_feature_enabled get_feature_flag_payload].each do |api|
    it "normalizes once and preserves caller inputs for #{api}" do
      before = Marshal.dump([groups, person_properties, group_properties])
      expect(client).to receive(:normalize_flag_evaluation_inputs).once.and_call_original
      call_options = options.dup
      if %i[get_feature_flag get_feature_flag_result is_feature_enabled].include?(api)
        call_options[:send_feature_flag_events] = false
      end
      bulk = %i[evaluate_flags get_all_flags get_all_flags_and_payloads].include?(api)
      args = bulk ? ['user'] : %w[group-flag user]
      result = client.public_send(api, *args, **call_options)

      case api
      when :evaluate_flags
        expect(result.get_flag('person-flag')).to be(true)
        expect(result.get_flag('group-flag')).to be(true)
      when :get_all_flags
        expect(result).to eq('person-flag' => true, 'group-flag' => true)
      when :get_all_flags_and_payloads
        expect(result[:featureFlags]).to eq('person-flag' => true, 'group-flag' => true)
      when :get_feature_flag_result
        expect(result.value).to be(true)
      when :get_feature_flag_payload
        expect(result).to eq('{"source":"local"}')
      else
        expect(result).to be(true)
      end
      expect(Marshal.dump([groups, person_properties, group_properties])).to eq(before)
      assert_not_requested :post, flags_endpoint
    end
  end

  it 'uses current property values on each call' do
    properties = { 'plan' => 'pro' }
    expect(client.evaluate_flags('user', person_properties: properties, only_evaluate_locally: true)
                 .get_flag('person-flag')).to be(true)
    properties['plan'] = 'free'
    expect(client.evaluate_flags('user', person_properties: properties, only_evaluate_locally: true)
                 .get_flag('person-flag')).to be(false)
    expect(properties).to eq('plan' => 'free')
  end

  [nil, 'caller-group-key'].each do |group_key|
    it "preserves remote request contents with group-key override #{group_key.inspect}" do
      person = { 'plan' => 'pro', 'detail' => { 'nested' => false }.freeze }.freeze
      company = { 'region' => 'US', 'detail' => { 'nested' => nil }.freeze }
      company['$group_key'] = group_key if group_key
      properties = { 'company' => company.freeze }.freeze
      requests = []
      stub_request(:post, flags_endpoint).to_return do |request|
        requests << JSON.parse(request.body)
        { status: 200, body: { featureFlags: {} }.to_json }
      end

      client.evaluate_flags('user', groups: groups, person_properties: person, group_properties: properties)

      expect(requests.length).to eq(1)
      expect(requests[0]['groups']).to eq(groups)
      expect(requests[0]['person_properties']).to eq(person)
      expect(requests[0]['group_properties']).to eq(
        'company' => { '$group_key' => group_key || 'acme', 'region' => 'US', 'detail' => { 'nested' => nil } }
      )
      expect(properties).to eq('company' => company)
      expect(person.keys).to eq(%w[plan detail])
    end
  end

  %i[hash object].each do |form|
    it "normalizes capture flag inputs once for #{form} options" do
      settings = { only_evaluate_locally: true, person_properties: person_properties,
                   group_properties: group_properties }
      flags = form == :hash ? settings.freeze : PostHog::SendFeatureFlagsOptions.new(**settings)
      poller = client.instance_variable_get(:@feature_flags_poller)
      expect(poller).to receive(:normalize_flag_evaluation_inputs).once.and_call_original
      before = Marshal.dump([groups, person_properties, group_properties])

      expect(client.capture(event: 'probe', distinct_id: 'user', groups: groups, send_feature_flags: flags)).to be(true)

      properties = client.dequeue_last_message[:properties]
      expect(properties['$feature/person-flag']).to be(true)
      expect(properties['$feature/group-flag']).to be(true)
      expect(Marshal.dump([groups, person_properties, group_properties])).to eq(before)
      assert_not_requested :post, flags_endpoint
    end
  end

  it 'preserves the remote capture flag context without adding group enrichment' do
    properties = { 'company' => { 'unmatched' => false }.freeze }.freeze
    flags = { person_properties: { 'unmatched' => nil }.freeze, group_properties: properties }.freeze
    requests = []
    stub_request(:post, flags_endpoint).to_return do |request|
      requests << JSON.parse(request.body)
      { status: 200, body: { featureFlags: {} }.to_json }
    end

    client.capture(event: 'probe', distinct_id: 'user', groups: groups, send_feature_flags: flags)

    expect(requests.length).to eq(1)
    expect(requests[0]['groups']).to eq(groups)
    expect(requests[0]['person_properties']).to eq('unmatched' => nil)
    expect(requests[0]['group_properties']).to eq(properties)
  end

  it 'normalizes boolean capture flag inputs once without changing caller groups' do
    poller = client.instance_variable_get(:@feature_flags_poller)
    expect(poller).to receive(:normalize_flag_evaluation_inputs).once.and_call_original

    expect(client.capture(event: 'probe', distinct_id: 'user', groups: groups, send_feature_flags: true)).to be(true)

    expect(groups).to eq('company' => 'acme')
    assert_requested :post, flags_endpoint, times: 1
  end
end
