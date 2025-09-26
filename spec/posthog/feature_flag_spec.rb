# frozen_string_literal: true

require 'spec_helper'
require 'timecop'

module PostHog
  RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil

  flags_endpoint = 'https://app.posthog.com/flags/?v=2'

  describe 'local evaluation' do
    it 'evaluates person properties' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'person-flag',
            'is_simple_flag' => true,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    {
                      'key' => 'region',
                      'operator' => 'exact',
                      'value' => ['USA'],
                      'type' => 'person'
                    }
                  ],
                  'rollout_percentage' => 100
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      # shouldn't call flags
      stub_request(:post, flags_endpoint)
        .to_return(status: 400)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_feature_flag('person-flag', 'some-distinct-id',
                                person_properties: { 'region' => 'USA' })).to eq(true)
      expect(c.get_feature_flag('person-flag', 'some-distinct-id',
                                person_properties: { 'region' => 'USA' })).to eq(true)
      expect(c.get_feature_flag('person-flag', 'some-distinct-id',
                                person_properties: { 'region' => 'Canada' })).to eq(false)
      expect(c.get_feature_flag('person-flag', 'some-distinct-id',
                                person_properties: { 'region' => 'Canada' })).to eq(false)
    end

    it 'evaluates group properties' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'group-flag',
            'is_simple_flag' => true,
            'active' => true,
            'filters' => {
              'aggregation_group_type_index' => 0,
              'groups' => [
                {
                  'properties' => [
                    {
                      'group_type_index' => 0,
                      'key' => 'name',
                      'operator' => 'exact',
                      'value' => ['Project Name 1'],
                      'type' => 'group'
                    }
                  ],
                  'rollout_percentage' => 35
                }
              ]
            }
          }
        ],
        'group_type_mapping' => { '0' => 'company', '1' => 'project' }
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      # shouldn't call flags
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'group-flag' => 'flags-fallback-value' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # groups not passed in, hence false
      expect(c.get_feature_flag('group-flag', 'some-distinct-id',
                                group_properties: { 'company' => { 'name' => 'Project Name 1' } })).to eq(false)
      expect(c.get_feature_flag('group-flag', 'some-distinct-id',
                                group_properties: { 'company' => { 'name' => 'Project Name 1' } })).to eq(false)
      expect(c.get_feature_flag('group-flag', 'some-distinct-2',
                                group_properties: { 'company' => { 'name' => 'Project Name 2' } })).to eq(false)

      # this is good
      expect(c.get_feature_flag(
               'group-flag',
               'some-distinct-2',
               groups: { 'company' => 'amazon_without_rollout' },
               group_properties: { 'company' => { 'name' => 'Project Name 1' } }
             )).to eq(true)
      expect(c.get_feature_flag(
               'group-flag',
               'some-distinct-2',
               groups: { 'company' => 'amazon_without_rollout' },
               group_properties: { 'company' => { 'name' => 'Project Name 1' } }
             )).to eq(true)
      expect(c.get_feature_flag(
               'group-flag',
               'some-distinct-2',
               groups: { 'company' => 'amazon_without_rollout' },
               group_properties: { 'company' => { 'name' => 'Project Name 1' } }
             )).to eq(true)

      # rollout % not met
      expect(c.get_feature_flag(
               'group-flag',
               'some-distinct-2',
               groups: { 'company' => 'amazon' },
               group_properties: { 'company' => { 'name' => 'Project Name 1' } }
             )).to eq(false)

      # property mismatch
      expect(c.get_feature_flag(
               'group-flag',
               'some-distinct-2',
               groups: { 'company' => 'amazon_without_rollout' },
               group_properties: { 'company' => { 'name' => 'Project Name 2' } }
             )).to eq(false)

      assert_not_requested :post, flags_endpoint
    end

    it 'evaluates group properties and falls back to server when group_type_mappings not present' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'group-flag',
            'is_simple_flag' => true,
            'active' => true,
            'filters' => {
              'aggregation_group_type_index' => 0,
              'groups' => [
                {
                  'properties' => [
                    {
                      'group_type_index' => 0,
                      'key' => 'name',
                      'operator' => 'exact',
                      'value' => ['Project Name 1'],
                      'type' => 'group'
                    }
                  ],
                  'rollout_percentage' => 35
                }
              ]
            }
          }
        ]
        # "group_type_mapping" => {}
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'group-flag' => 'flags-fallback-value' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # group_type_mappings not present, so fallback to `/flags`
      expect(c.get_feature_flag(
               'group-flag',
               'some-distinct-2',
               groups: { 'company' => 'amazon' },
               group_properties: { 'company' => { 'name' => 'Project Name 2' } }
             )).to eq('flags-fallback-value')
      assert_requested :post, flags_endpoint, times: 1
    end

    it 'evaluates flag with complex definition' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'complex-flag',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    {
                      'key' => 'region',
                      'operator' => 'exact',
                      'value' => ['USA'],
                      'type' => 'person'
                    },
                    {
                      'key' => 'name',
                      'operator' => 'exact',
                      'value' => ['Aloha'],
                      'type' => 'person'
                    }
                  ],
                  'rollout_percentage' => 100
                },
                {
                  'properties' => [
                    {
                      'key' => 'email',
                      'operator' => 'exact',
                      'value' => ['a@b.com', 'b@c.com'],
                      'type' => 'person'
                    }
                  ],
                  'rollout_percentage' => 30
                },
                {
                  'properties' => [
                    {
                      'key' => 'doesnt_matter',
                      'operator' => 'exact',
                      'value' => %w[1 2],
                      'type' => 'person'
                    }
                  ],
                  'rollout_percentage' => 0
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'complex-flag' => 'flags-fallback-value' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_feature_flag('complex-flag', 'some-distinct-id',
                                person_properties: { 'region' => 'USA', 'name' => 'Aloha' })).to eq(true)
      expect(c.get_feature_flag('complex-flag', 'some-distinct-id',
                                person_properties: { 'region' => 'USA', 'name' => 'Aloha' })).to eq(true)
      assert_not_requested :post, flags_endpoint

      # this distinctIDs hash is < rollout %
      expect(c.get_feature_flag('complex-flag', 'some-distinct-id_within_rollout?',
                                person_properties: { 'region' => 'USA', 'email' => 'a@b.com' })).to eq(true)
      assert_not_requested :post, flags_endpoint

      # will fall back on `/flags`, as all properties present for second group, but that group resolves to false
      expect(c.get_feature_flag(
               'complex-flag',
               'some-distinct-id_outside_rollout?',
               person_properties: { 'region' => 'USA',
                                    'email' => 'a@b.com' }
             )).to eq('flags-fallback-value')
      assert_requested :post, flags_endpoint, times: 1
      expect(WebMock).to have_requested(:post, flags_endpoint).with(
        body: {
          'distinct_id' => 'some-distinct-id_outside_rollout?',
          'groups' => {},
          'group_properties' => {},
          'person_properties' => { 'distinct_id' => 'some-distinct-id_outside_rollout?', 'region' => 'USA',
                                   'email' => 'a@b.com' },
          'token' => 'testsecret'
        }
      )

      WebMock.reset_executed_requests!

      # same as above
      expect(c.get_feature_flag('complex-flag', 'some-distinct-id',
                                person_properties: { 'doesnt_matter' => '1' })).to eq('flags-fallback-value')
      assert_requested :post, flags_endpoint, times: 1

      expect(WebMock).to have_requested(:post, flags_endpoint).with(
        body: {
          'distinct_id' => 'some-distinct-id',
          'groups' => {},
          'group_properties' => {},
          'person_properties' => { 'distinct_id' => 'some-distinct-id', 'doesnt_matter' => '1' },
          'token' => 'testsecret'
        }
      )

      WebMock.reset_executed_requests!

      expect(c.get_feature_flag(
               'complex-flag',
               'some-distinct-id',
               person_properties: { 'region' => 'USA' }
             )).to eq('flags-fallback-value')
      assert_requested :post, flags_endpoint, times: 1
      WebMock.reset_executed_requests!

      # won't need to fallback when all values are present, and resolves to False
      expect(c.get_feature_flag(
               'complex-flag',
               'some-distinct-id_outside_rollout?',
               person_properties: {
                 'region' => 'USA',
                 'email' => 'a@b.com',
                 'name' => 'X',
                 'doesnt_matter' => '1'
               }
             )).to eq(false)
      assert_not_requested :post, flags_endpoint
    end

    it 'falls back to server' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [{ 'key' => 'id', 'value' => 98, 'operator' => nil, 'type' => 'cohort' }],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature',
            'key' => 'beta-feature2',
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    {
                      'key' => 'region',
                      'operator' => 'exact',
                      'value' => ['USA'],
                      'type' => 'person'
                    }
                  ],
                  'rollout_percentage' => 100
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'alakazam',
                                                            'beta-feature2' => 'alakazam2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature fallbacks to server because property type is unknown
      expect(c.get_feature_flag('beta-feature', 'some-distinct-id')).to eq('alakazam')
      assert_requested :post, flags_endpoint, times: 1
      WebMock.reset_executed_requests!

      # beta-feature2 fallbacks to server because region property not given with call
      expect(c.get_feature_flag('beta-feature2', 'some-distinct-id')).to eq('alakazam2')
      assert_requested :post, flags_endpoint, times: 1
      WebMock.reset_executed_requests!
    end

    it 'dont fall back to server when local evaluation is set' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [{ 'key' => 'id', 'value' => 98, 'operator' => nil, 'type' => 'cohort' }],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature',
            'key' => 'beta-feature2',
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    {
                      'key' => 'region',
                      'operator' => 'exact',
                      'value' => ['USA'],
                      'type' => 'person'
                    }
                  ],
                  'rollout_percentage' => 100
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'alakazam',
                                                            'beta-feature2' => 'alakazam2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature should fallback to server because property type is unknown
      # but doesn't because only_evaluate_locally is true
      expect(c.get_feature_flag('beta-feature', 'some-distinct-id', only_evaluate_locally: true)).to be(nil)
      expect(c.is_feature_enabled('beta-feature', 'some-distinct-id', only_evaluate_locally: true)).to be(nil)
      assert_not_requested :post, flags_endpoint

      # beta-feature2 should fallback to server because region property not given with call
      # but doesn't because only_evaluate_locally is true
      expect(c.get_feature_flag('beta-feature2', 'some-distinct-id', only_evaluate_locally: true)).to be(nil)
      expect(c.is_feature_enabled('beta-feature2', 'some-distinct-id', only_evaluate_locally: true)).to be(nil)
      assert_not_requested :post, flags_endpoint
    end

    it "doesn't return undefined when flag is evaluated successfully" do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => true,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 0
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature2',
            'key' => 'beta-feature2',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [{ 'key' => 'region', 'value' => 'US', 'operator' => 'exact',
                                     'type' => 'person' }],
                  'rollout_percentage' => 100
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => {} }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature resolves to False, so no matter the default, stays False
      expect(c.get_feature_flag('beta-feature', 'some-distinct-id')).to be(false)
      expect(c.is_feature_enabled('beta-feature', 'some-distinct-id')).to be(false)
      assert_not_requested :post, flags_endpoint

      # beta-feature2 falls back to server, and whatever server returns is the value
      expect(c.get_feature_flag('beta-feature2', 'some-distinct-id')).to be(false)
      expect(c.is_feature_enabled('beta-feature2', 'some-distinct-id')).to be(false)
      assert_requested :post, flags_endpoint, times: 2
      WebMock.reset_executed_requests!
    end

    it 'returns undefined when `/flags` errors out' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => true,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 0
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature2',
            'key' => 'beta-feature2',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [{ 'key' => 'region', 'value' => 'US', 'operator' => 'exact',
                                     'type' => 'person' }],
                  'rollout_percentage' => 100
                }
              ]
            }
          }
        ]
      }
      # We don't go to `/flags` if local eval is enabled and the flag is not in list of all flag definitions
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 400, body: { 'error' => 'went wrong!' }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature2 falls back to server, which on error returns default
      expect(c.get_feature_flag('beta-feature2', 'some-distinct-id')).to be(nil)
      expect(c.is_feature_enabled('beta-feature2', 'some-distinct-id')).to be(nil)
      assert_requested :post, flags_endpoint, times: 2
      WebMock.reset_executed_requests!
    end

    it 'returns undefined when `/flags` or `/local_evaluation` times out' do
      # TRICKY: Pretty hard to simulate a timeout using sleep with WebMock, so we'll just raise an error
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_raise(Net::ReadTimeout)

      stub_request(:post, flags_endpoint)
        .to_raise(Net::ReadTimeout)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature falls back to `/flags`, which on error returns default
      expect(c.get_feature_flag('beta-feature', 'some-distinct-id')).to be(nil)
      assert_requested :post, flags_endpoint, times: 1
      WebMock.reset_executed_requests!

      # beta-feature2 falls back to `/flags`, which on error returns default
      expect(c.get_feature_flag('beta-feature2', 'some-distinct-id')).to be(nil)
      expect(c.is_feature_enabled('beta-feature2', 'some-distinct-id')).to be(nil)
      assert_requested :post, flags_endpoint, times: 2
      WebMock.reset_executed_requests!

      expect(c.get_all_flags('some-distinct-id')).to eq({})
      assert_requested :post, flags_endpoint, times: 1
      WebMock.reset_executed_requests!
    end

    it 'experience continuity flags are not evaluated locally' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => true,
            'active' => true,
            'ensure_experience_continuity' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 0
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'flags-fallback-value' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature2 falls back to `/flags`, which on error returns default
      expect(c.get_feature_flag('beta-feature', 'some-distinct-id')).to eq('flags-fallback-value')
      assert_requested :post, flags_endpoint, times: 1
    end

    it 'get all flags with fallback' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => true,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature',
            'key' => 'disabled-feature',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 0
                }
              ]
            }
          },
          {
            'id' => 3,
            'name' => 'Beta Feature',
            'key' => 'beta-feature2',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [{ 'key' => 'country', 'value' => 'US' }],
                  'rollout_percentage' => 0
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(
          status: 200,
          body: { 'featureFlags' => { 'beta-feature' => 'variant-1', 'beta-feature2' => 'variant-2',
                                      'disabled-feature' => false } }.to_json
        )

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature value overridden by `/flags`
      expect(c.get_all_flags('distinct-id')).to eq({ 'beta-feature' => 'variant-1', 'beta-feature2' => 'variant-2',
                                                     'disabled-feature' => false })
      assert_requested :post, flags_endpoint, times: 1
      WebMock.reset_executed_requests!
    end

    it 'get all flags with fallback but only_locally_evaluated set' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => true,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature',
            'key' => 'disabled-feature',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 0
                }
              ]
            }
          },
          {
            'id' => 3,
            'name' => 'Beta Feature',
            'key' => 'beta-feature2',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [{ 'key' => 'country', 'value' => 'US' }],
                  'rollout_percentage' => 0
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'variant-1',
                                                            'beta-feature2' => 'variant-2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # beta-feature2 has no value
      expect(c.get_all_flags('distinct-id',
                             only_evaluate_locally: true)).to eq({ 'beta-feature' => true,
                                                                   'disabled-feature' => false })
      assert_not_requested :post, flags_endpoint
    end

    it 'get all flags with fallback, with no local flags' do
      api_feature_flag_res = {
        'flags' => []
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'variant-1',
                                                            'beta-feature2' => 'variant-2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_all_flags('distinct-id')).to eq({ 'beta-feature' => 'variant-1', 'beta-feature2' => 'variant-2' })
      assert_requested :post, flags_endpoint, times: 1
      WebMock.reset_executed_requests!
    end

    it 'get all flags with no fallback' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => true,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature',
            'key' => 'disabled-feature',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 0
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'variant-1',
                                                            'beta-feature2' => 'variant-2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_all_flags('distinct-id')).to eq({ 'beta-feature' => true, 'disabled-feature' => false })
      assert_not_requested :post, flags_endpoint
    end

    it 'computes inactive flags locally as well' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => true,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature',
            'key' => 'disabled-feature',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 0
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'variant-1',
                                                            'beta-feature2' => 'variant-2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_all_flags('distinct-id')).to eq({ 'beta-feature' => true, 'disabled-feature' => false })
      assert_not_requested :post, flags_endpoint

      # Now, after a poll interval, flag 1 is inactive, and flag 2 rollout is set to 100%.
      api_feature_flag_res_updated = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => false,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 100
                }
              ]
            }
          },
          {
            'id' => 2,
            'name' => 'Beta Feature',
            'key' => 'disabled-feature',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [],
                  'rollout_percentage' => 100
                }
              ]
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res_updated.to_json)

      # force reload to simulate poll interval
      c.reload_feature_flags

      expect(c.get_all_flags('distinct-id')).to eq({ 'beta-feature' => false, 'disabled-feature' => true })
      assert_not_requested :post, flags_endpoint
    end

    it 'gets feature flag with variant overrides' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => true,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    { 'key' => 'email', 'type' => 'person', 'value' => 'test@posthog.com',
                      'operator' => 'exact' }
                  ],
                  'rollout_percentage' => 100,
                  'variant' => 'second-variant'
                },
                { 'rollout_percentage' => 50, 'variant' => 'first-variant' }
              ],
              'multivariate' => {
                'variants' => [
                  { 'key' => 'first-variant', 'name' => 'First Variant', 'rollout_percentage' => 50 },
                  { 'key' => 'second-variant', 'name' => 'Second Variant', 'rollout_percentage' => 25 },
                  { 'key' => 'third-variant', 'name' => 'Third Variant', 'rollout_percentage' => 25 }
                ]
              }
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'variant-1',
                                                            'beta-feature2' => 'variant-2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_feature_flag('beta-feature', 'test_id',
                                person_properties: { 'email' => 'test@posthog.com' })).to eq('second-variant')
      expect(c.get_feature_flag('beta-feature', 'example_id')).to eq('first-variant')
      assert_not_requested :post, flags_endpoint
    end

    it 'gets feature flag with clashing variant overrides' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => true,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    { 'key' => 'email', 'type' => 'person', 'value' => 'test@posthog.com',
                      'operator' => 'exact' }
                  ],
                  'rollout_percentage' => 100,
                  'variant' => 'second-variant'
                },
                # since second-variant comes first in the list, it will be the one that gets picked
                {
                  'properties' => [
                    { 'key' => 'email', 'type' => 'person', 'value' => 'test@posthog.com',
                      'operator' => 'exact' }
                  ],
                  'rollout_percentage' => 100,
                  'variant' => 'first-variant'
                },
                { 'rollout_percentage' => 50, 'variant' => 'first-variant' }
              ],
              'multivariate' => {
                'variants' => [
                  { 'key' => 'first-variant', 'name' => 'First Variant', 'rollout_percentage' => 50 },
                  { 'key' => 'second-variant', 'name' => 'Second Variant', 'rollout_percentage' => 25 },
                  { 'key' => 'third-variant', 'name' => 'Third Variant', 'rollout_percentage' => 25 }
                ]
              }
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'variant-1',
                                                            'beta-feature2' => 'variant-2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_feature_flag('beta-feature', 'test_id',
                                person_properties: { 'email' => 'test@posthog.com' })).to eq('second-variant')
      expect(c.get_feature_flag('beta-feature', 'example_id',
                                person_properties: { 'email' => 'test@posthog.com' })).to eq('second-variant')
      assert_not_requested :post, flags_endpoint
    end

    it 'gets feature flag with invalid variant overrides' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'beta-feature',
            'is_simple_flag' => false,
            'active' => true,
            'rollout_percentage' => 100,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    { 'key' => 'email', 'type' => 'person', 'value' => 'test@posthog.com',
                      'operator' => 'exact' }
                  ],
                  'rollout_percentage' => 100,
                  'variant' => 'second???'
                },
                { 'rollout_percentage' => 50, 'variant' => 'first??' }
              ],
              'multivariate' => {
                'variants' => [
                  { 'key' => 'first-variant', 'name' => 'First Variant', 'rollout_percentage' => 50 },
                  { 'key' => 'second-variant', 'name' => 'Second Variant', 'rollout_percentage' => 25 },
                  { 'key' => 'third-variant', 'name' => 'Third Variant', 'rollout_percentage' => 25 }
                ]
              }
            }
          }
        ]
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'beta-feature' => 'variant-1',
                                                            'beta-feature2' => 'variant-2' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_feature_flag('beta-feature', 'test_id',
                                person_properties: { 'email' => 'test@posthog.com' })).to eq('third-variant')
      expect(c.get_feature_flag('beta-feature', 'example_id')).to eq('second-variant')
      assert_not_requested :post, flags_endpoint
    end

    it 'evaluates condition sets in original order' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Order Test',
            'key' => 'order-test',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'rollout_percentage' => 100
                },
                {
                  'properties' => [
                    {
                      'key' => 'email',
                      'type' => 'person',
                      'value' => '@vip.com',
                      'operator' => 'icontains'
                    }
                  ],
                  'variant' => 'vip-variant'
                }
              ],
              'multivariate' => {
                'variants' => [
                  {
                    'key' => 'control',
                    'name' => 'Control',
                    'rollout_percentage' => 100
                  },
                  {
                    'key' => 'vip-variant',
                    'name' => 'VIP Variant',
                    'rollout_percentage' => 0
                  }
                ]
              }
            }
          }
        ]
      }

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint).to_return(status: 400)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # Even for a user with a VIP email, the first condition (with 100% rollout) is evaluated,
      # resulting in the "control" variant, rather than sorting conditions with variant overrides to the top
      result = c.get_feature_flag('order-test', 'user123', person_properties: { 'email' => 'user@vip.com' })
      expect(result).to eq('control')

      assert_not_requested :post, flags_endpoint
    end
  end

  describe 'property matching' do
    it 'with operator exact' do
      property_a = { 'key' => 'key', 'value' => 'value' }

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value' })).to be true

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value2' })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '' })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => nil })).to be false

      expect do
        FeatureFlagsPoller.match_property(property_a, { 'key2' => 'value' })
      end.to raise_error(InconclusiveMatchError)
      expect { FeatureFlagsPoller.match_property(property_a, {}) }.to raise_error(InconclusiveMatchError)

      property_b = { 'key' => 'key', 'value' => 'value', 'operator' => 'exact' }

      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 'value' })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 'value2' })).to be false

      property_c = { 'key' => 'key', 'value' => %w[value1 value2 value3], 'operator' => 'exact' }
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value1' })).to be true
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value2' })).to be true
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value3' })).to be true

      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value4' })).to be false

      expect do
        FeatureFlagsPoller.match_property(property_c, { 'key2' => 'value' })
      end.to raise_error(InconclusiveMatchError)
    end

    it 'with operator is_not' do
      property_a = { 'key' => 'key', 'value' => 'value', 'operator' => 'is_not' }

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value' })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value2' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => nil })).to be true

      expect do
        FeatureFlagsPoller.match_property(property_a, { 'key2' => 'value' })
      end.to raise_error(InconclusiveMatchError)
      expect { FeatureFlagsPoller.match_property(property_a, {}) }.to raise_error(InconclusiveMatchError)

      property_c = { 'key' => 'key', 'value' => %w[value1 value2 value3], 'operator' => 'is_not' }
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value1' })).to be false
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value2' })).to be false
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value3' })).to be false

      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value4' })).to be true
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value5' })).to be true
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => '' })).to be true
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => nil })).to be true

      expect do
        FeatureFlagsPoller.match_property(property_c, { 'key2' => 'value' })
      end.to raise_error(InconclusiveMatchError)
    end

    it 'with operator is_set' do
      property_a = { 'key' => 'key', 'value' => 'is_set', 'operator' => 'is_set' }

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value2' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => nil })).to be true

      expect do
        FeatureFlagsPoller.match_property(property_a, { 'key2' => 'value' })
      end.to raise_error(InconclusiveMatchError)
      expect { FeatureFlagsPoller.match_property(property_a, {}) }.to raise_error(InconclusiveMatchError)
    end

    it 'with operator icontains' do
      property_a = { 'key' => 'key', 'value' => 'vaLuE', 'operator' => 'icontains' }

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value2' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'vaLue3' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '343tfvalUe5' })).to be true

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '' })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => nil })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 1234 })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '1234' })).to be false

      expect do
        FeatureFlagsPoller.match_property(property_a, { 'key2' => 'value' })
      end.to raise_error(InconclusiveMatchError)
      expect { FeatureFlagsPoller.match_property(property_a, {}) }.to raise_error(InconclusiveMatchError)

      property_b = { 'key' => 'key', 'value' => '3', 'operator' => 'icontains' }

      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '3' })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 323 })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 'val3' })).to be true

      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 'three' })).to be false
    end

    it 'with operator regex' do
      property_a = { 'key' => 'key', 'value' => '\.com$', 'operator' => 'regex' }

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value.com' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value2.com' })).to be true

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'valuecom' })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'value\com' })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '.com343tfvalue5' })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => nil })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '' })).to be false

      expect do
        FeatureFlagsPoller.match_property(property_a, { 'key2' => 'value' })
      end.to raise_error(InconclusiveMatchError)
      expect { FeatureFlagsPoller.match_property(property_a, {}) }.to raise_error(InconclusiveMatchError)

      property_b = { 'key' => 'key', 'value' => '3', 'operator' => 'regex' }

      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '3' })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 323 })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 'val3' })).to be true

      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 'three' })).to be false

      # invalid regex
      property_c = { 'key' => 'key', 'value' => '?*', 'operator' => 'regex' }
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value.com' })).to be false
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'value2' })).to be false

      # non string value
      property_d = { 'key' => 'key', 'value' => 4, 'operator' => 'regex' }
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '4' })).to be true
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => 4 })).to be true

      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => 'value' })).to be false

      # non string value - not_regex
      property_d = { 'key' => 'key', 'value' => 4, 'operator' => 'not_regex' }
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '4' })).to be false
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => 4 })).to be false

      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => 'value' })).to be true
    end

    it 'with math operators' do
      property_a = { 'key' => 'key', 'value' => 1, 'operator' => 'gt' }

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 2 })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 3 })).to be true

      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 0 })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => -1 })).to be false
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '23' })).to be true

      property_b = { 'key' => 'key', 'value' => 1, 'operator' => 'lt' }
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 0 })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => -1 })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => -3 })).to be true

      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '3' })).to be false
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '1' })).to be false
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => 1 })).to be false

      property_c = { 'key' => 'key', 'value' => 1, 'operator' => 'gte' }
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 2 })).to be true
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 1 })).to be true

      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 0 })).to be false
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => -1 })).to be false
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => -3 })).to be false
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => '3' })).to be true

      property_d = { 'key' => 'key', 'value' => '43', 'operator' => 'lte' }
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '43' })).to be true
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '42' })).to be true

      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '44' })).to be false
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => 44 })).to be false
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => 42 })).to be true

      property_e = { 'key' => 'key', 'value' => '30', 'operator' => 'lt' }
      expect(FeatureFlagsPoller.match_property(property_e, { 'key' => '29' })).to be true

      # depending on the type of override, we adjust type comparison
      expect(FeatureFlagsPoller.match_property(property_e, { 'key' => '100' })).to be true
      expect(FeatureFlagsPoller.match_property(property_e, { 'key' => 100 })).to be false

      property_f = { 'key' => 'key', 'value' => '123aloha', 'operator' => 'gt' }
      expect(FeatureFlagsPoller.match_property(property_f, { 'key' => '123' })).to be false
      expect(FeatureFlagsPoller.match_property(property_f, { 'key' => 122 })).to be false

      # this turns into a string comparison
      expect(FeatureFlagsPoller.match_property(property_f, { 'key' => 129 })).to be true
    end

    it 'with date operators' do
      # is date before
      property_a = { 'key' => 'key', 'value' => '2022-05-01', 'operator' => 'is_date_before' }
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '2022-03-01' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '2022-04-30' })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => DateTime.new(2022, 4, 30) })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => DateTime.new(2022, 4, 30, 1, 2, 3) })).to be true
      expect(FeatureFlagsPoller.match_property(property_a,
                                               { 'key' => DateTime.new(2022, 4, 30, 1, 2, 3, '+2') })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => DateTime.parse('2022-04-30') })).to be true
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '2022-05-30' })).to be false

      # error handling
      expect { FeatureFlagsPoller.match_property(property_a, { 'key' => 1 }) }.to raise_error(InconclusiveMatchError)
      expect do
        FeatureFlagsPoller.match_property(property_a, { 'key' => 'abcdef' })
      end.to raise_error(InconclusiveMatchError)

      # is date after
      property_b = { 'key' => 'key', 'value' => '2022-05-01', 'operator' => 'is_date_after' }
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '2022-05-02' })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '2022-05-30' })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => DateTime.new(2022, 5, 30) })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => DateTime.new(2022, 5, 1, 1, 2, 3) })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => DateTime.parse('2022-05-30') })).to be true
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '2022-04-30' })).to be false

      # invalid flag property
      property_c = { 'key' => 'key', 'value' => 1234, 'operator' => 'is_date_before' }
      expect do
        FeatureFlagsPoller.match_property(property_c, { 'key' => '2022-05-30' })
      end.to raise_error(InconclusiveMatchError)

      # timezone aware property
      property_d = { 'key' => 'key', 'value' => '2022-04-05T12:34:12+01:00', 'operator' => 'is_date_before' }
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-05-30' })).to be false
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-03-30' })).to be true
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-04-05 12:34:11 +01:00' })).to be true
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-04-05 12:34:13 +01:00' })).to be false
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-04-05 11:34:11 +00:00' })).to be true
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-04-05 11:34:13 +00:00' })).to be false
    end

    it 'with relative date operators - is_date_before' do
      Timecop.freeze(Time.gm(2022, 5, 1)) do
        property_a = { 'key' => 'key', 'value' => '-6h', 'operator' => 'is_date_before' }
        expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '2022-03-01' })).to be true
        expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '2022-04-30' })).to be true
        expect(FeatureFlagsPoller.match_property(property_a,
                                                 { 'key' => DateTime.new(2022, 4, 30, 1, 2, 3) })).to be true
        # false because date comparison, instead of datetime, so reduces to same date
        # we converts this to datetime for appropriate comparison anyway
        expect(FeatureFlagsPoller.match_property(property_a,
                                                 { 'key' => DateTime.new(2022, 4, 30, 19, 2, 3) })).to be false

        expect(FeatureFlagsPoller.match_property(property_a,
                                                 { 'key' => DateTime.new(2022, 4, 30, 1, 2, 3, '+2') })).to be true
        expect(FeatureFlagsPoller.match_property(property_a,
                                                 { 'key' => DateTime.new(2022, 4, 30, 20, 2, 3, '+2') })).to be false
        expect(FeatureFlagsPoller.match_property(property_a,
                                                 { 'key' => DateTime.new(2022, 4, 30, 19, 59, 3, '+2') })).to be true
        expect(FeatureFlagsPoller.match_property(property_a, { 'key' => DateTime.parse('2022-04-30') })).to be true
        expect(FeatureFlagsPoller.match_property(property_a, { 'key' => '2022-05-30' })).to be false

        # can't be a number
        expect { FeatureFlagsPoller.match_property(property_a, { 'key' => 1 }) }.to raise_error(InconclusiveMatchError)

        # can't be invalid string
        expect do
          FeatureFlagsPoller.match_property(property_a, { 'key' => 'abcdef' })
        end.to raise_error(InconclusiveMatchError)
      end
    end

    it 'with relative date operators - is_date_after' do
      Timecop.freeze(Time.gm(2022, 5, 1)) do
        property_b = { 'key' => 'key', 'value' => '1h', 'operator' => 'is_date_after' }
        expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '2022-05-02' })).to be true
        expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '2022-05-30' })).to be true
        expect(FeatureFlagsPoller.match_property(property_b, { 'key' => DateTime.new(2022, 5, 30) })).to be true
        expect(FeatureFlagsPoller.match_property(property_b, { 'key' => DateTime.parse('2022-05-30') })).to be true
        expect(FeatureFlagsPoller.match_property(property_b, { 'key' => '2022-04-30' })).to be false

        # can't be invalid string
        expect do
          FeatureFlagsPoller.match_property(property_b, { 'key' => 'abcdef' })
        end.to raise_error(InconclusiveMatchError)
        # invalid flag property
        property_c = { 'key' => 'key', 'value' => 1234, 'operator' => 'is_date_after' }
        expect { FeatureFlagsPoller.match_property(property_c, { 'key' => 1 }) }.to raise_error(InconclusiveMatchError)
        expect do
          FeatureFlagsPoller.match_property(property_c, { 'key' => '2022-05-30' })
        end.to raise_error(InconclusiveMatchError)
      end
    end

    it 'with relative date operators - all possible relative dates' do
      Timecop.freeze(Time.gm(2022, 5, 1)) do
        property_d = { 'key' => 'key', 'value' => '-12d', 'operator' => 'is_date_before' }
        expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-05-30' })).to be false

        expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-03-30' })).to be true
        expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-04-05 12:34:11+01:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-04-19 01:34:11+02:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_d, { 'key' => '2022-04-19 02:00:01+02:00' })).to be false

        # Try all possible relative dates
        property_e = { 'key' => 'key', 'value' => '1h', 'operator' => 'is_date_before' }
        expect(FeatureFlagsPoller.match_property(property_e, { 'key' => '2022-05-01 00:00:00' })).to be false
        expect(FeatureFlagsPoller.match_property(property_e, { 'key' => '2022-04-30 22:00:00' })).to be true

        property_f = { 'key' => 'key', 'value' => '1d', 'operator' => 'is_date_before' }
        expect(FeatureFlagsPoller.match_property(property_f, { 'key' => '2022-04-29 23:59:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_f, { 'key' => '2022-04-30 00:00:01' })).to be false

        property_g = { 'key' => 'key', 'value' => '1w', 'operator' => 'is_date_before' }
        expect(FeatureFlagsPoller.match_property(property_g, { 'key' => '2022-04-23 00:00:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_g, { 'key' => '2022-04-24 00:00:00' })).to be false
        expect(FeatureFlagsPoller.match_property(property_g, { 'key' => '2022-04-24 00:00:01' })).to be false

        property_h = { 'key' => 'key', 'value' => '1m', 'operator' => 'is_date_before' }
        expect(FeatureFlagsPoller.match_property(property_h, { 'key' => '2022-03-01 00:00:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_h, { 'key' => '2022-04-05 00:00:00' })).to be false

        property_i = { 'key' => 'key', 'value' => '1y', 'operator' => 'is_date_before' }
        expect(FeatureFlagsPoller.match_property(property_i, { 'key' => '2021-04-28 00:00:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_i, { 'key' => '2021-05-01 00:00:01' })).to be false

        property_j = { 'key' => 'key', 'value' => '122h', 'operator' => 'is_date_after' }
        expect(FeatureFlagsPoller.match_property(property_j, { 'key' => '2022-05-01 00:00:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_j, { 'key' => '2022-04-23 01:00:00' })).to be false

        property_k = { 'key' => 'key', 'value' => '-2d', 'operator' => 'is_date_after' }
        expect(FeatureFlagsPoller.match_property(property_k, { 'key' => '2022-05-01 00:00:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_k, { 'key' => '2022-04-29 00:00:01' })).to be true
        expect(FeatureFlagsPoller.match_property(property_k, { 'key' => '2022-04-29 00:00:00' })).to be false

        property_l = { 'key' => 'key', 'value' => '02w', 'operator' => 'is_date_after' }
        expect(FeatureFlagsPoller.match_property(property_l, { 'key' => '2022-05-01 00:00:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_l, { 'key' => '2022-04-16 00:00:00' })).to be false

        property_m = { 'key' => 'key', 'value' => '1m', 'operator' => 'is_date_after' }
        expect(FeatureFlagsPoller.match_property(property_m, { 'key' => '2022-04-01 00:00:01' })).to be true
        expect(FeatureFlagsPoller.match_property(property_m, { 'key' => '2022-04-01 00:00:00' })).to be false

        property_n = { 'key' => 'key', 'value' => '1y', 'operator' => 'is_date_after' }
        expect(FeatureFlagsPoller.match_property(property_n, { 'key' => '2022-05-01 00:00:00' })).to be true
        expect(FeatureFlagsPoller.match_property(property_n, { 'key' => '2021-05-01 00:00:01' })).to be true
        expect(FeatureFlagsPoller.match_property(property_n, { 'key' => '2021-05-01 00:00:00' })).to be false
        expect(FeatureFlagsPoller.match_property(property_n, { 'key' => '2021-04-30 00:00:00' })).to be false
        expect(FeatureFlagsPoller.match_property(property_n, { 'key' => '2021-03-01 12:13:00' })).to be false
      end
    end

    it 'with none property value with all operators' do
      property_a = { 'key' => 'key', 'value' => 'nil', 'operator' => 'is_not' }
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => nil })).to be true
      # nil to string here is an empty string, not "nil" so it's true because it doesn't match
      expect(FeatureFlagsPoller.match_property(property_a, { 'key' => 'ni' })).to be true

      property_b = { 'key' => 'key', 'value' => nil, 'operator' => 'is_set' }
      expect(FeatureFlagsPoller.match_property(property_b, { 'key' => nil })).to be true
      expect { FeatureFlagsPoller.match_property(property_b, {}) }.to raise_error(InconclusiveMatchError)

      property_c = { 'key' => 'key', 'value' => 'ni', 'operator' => 'icontains' }
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => nil })).to be false
      expect(FeatureFlagsPoller.match_property(property_c, { 'key' => 'smh' })).to be false

      property_d = { 'key' => 'key', 'value' => 'Ni', 'operator' => 'regex' }
      expect(FeatureFlagsPoller.match_property(property_d, { 'key' => nil })).to be false

      property_d_lower_case = { 'key' => 'key', 'value' => 'ni', 'operator' => 'regex' }
      expect(FeatureFlagsPoller.match_property(property_d_lower_case, { 'key' => nil })).to be false

      property_e = { 'key' => 'key', 'value' => 1, 'operator' => 'gt' }
      expect(FeatureFlagsPoller.match_property(property_e, { 'key' => nil })).to be false

      property_f = { 'key' => 'key', 'value' => 1, 'operator' => 'lt' }
      expect(FeatureFlagsPoller.match_property(property_f, { 'key' => nil })).to be true

      property_g = { 'key' => 'key', 'value' => 'xyz', 'operator' => 'gte' }
      expect(FeatureFlagsPoller.match_property(property_g, { 'key' => nil })).to be false

      property_j = { 'key' => 'key', 'value' => '2022-05-01', 'operator' => 'is_date_after' }
      expect { FeatureFlagsPoller.match_property(property_j, { 'key' => nil }) }.to raise_error(InconclusiveMatchError)

      property_k = { 'key' => 'key', 'value' => '2022-05-01', 'operator' => 'is_date_before' }
      expect do
        FeatureFlagsPoller.match_property(property_k, { 'key' => 'random' })
      end.to raise_error(InconclusiveMatchError)
    end

    it 'with invalid operator' do
      property_a = { 'key' => 'key', 'value' => '2022-05-01', 'operator' => 'is_unknown' }
      begin
        expect do
          FeatureFlagsPoller.match_property(property_a, { 'key' => 'random' })
        end.to raise_error(InconclusiveMatchError)
        FeatureFlagsPoller.match_property(property_a, { 'key' => 'random' })
      rescue InconclusiveMatchError => e
        expect(e.message).to eq('Unknown operator: is_unknown')
      end
    end
  end

  describe 'relative date parsing' do
    it 'invalid input' do
      Timecop.freeze(Time.gm(2022, 5, 1)) do
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1x')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1.2y')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1z')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1s')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('123344000.134m')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('bazinga')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('000bello')).to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('000hello')).to be_nil

        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('000h')).not_to be_nil
        expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1000h')).not_to be_nil
      end
    end

    it 'test overflow' do
      expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1000000h')).to be_nil
      expect(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('100000000000000000y')).to be_nil
    end

    it 'test hour parsing' do
      Timecop.freeze(Time.gm(2020, 1, 1, 12, 1, 20, 134_000, 0)) do
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1h')
        ).to eq(DateTime.new(2020, 1, 1,
                             11, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('2h')
        ).to eq(DateTime.new(2020, 1, 1,
                             10, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('24h')
        ).to eq(DateTime.new(2019, 12,
                             31, 12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('30h')
        ).to eq(DateTime.new(2019, 12,
                             31, 6, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('48h')
        ).to eq(DateTime.new(2019, 12,
                             30, 12, 1, 20, Rational(0, 24)))

        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('24h')
        ).to eq(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1d'))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('48h')
        ).to eq(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('2d'))
      end
    end

    it 'test day parsing' do
      Timecop.freeze(Time.gm(2020, 1, 1, 12, 1, 20, 134_000, 0)) do
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1d')
        ).to eq(DateTime.new(2019, 12, 31,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('2d')
        ).to eq(DateTime.new(2019, 12, 30,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('7d')
        ).to eq(DateTime.new(2019, 12, 25,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('14d')
        ).to eq(DateTime.new(2019, 12,
                             18, 12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('30d')
        ).to eq(DateTime.new(2019, 12, 2,
                             12, 1, 20, Rational(0, 24)))

        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('7d')
        ).to eq(FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1w'))
      end
    end

    it 'test week parsing' do
      Timecop.freeze(Time.gm(2020, 1, 1, 12, 1, 20, 134_000, 0)) do
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1w')
        ).to eq(DateTime.new(2019, 12, 25,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('2w')
        ).to eq(DateTime.new(2019, 12, 18,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('4w')
        ).to eq(DateTime.new(2019, 12, 4,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('8w')
        ).to eq(DateTime.new(2019, 11, 6,
                             12, 1, 20, Rational(0, 24)))

        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1m')
        ).to eq(DateTime.new(2019, 12, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('4w')
        ).not_to eq(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1m')
        )
      end
    end

    it 'test month parsing' do
      Timecop.freeze(Time.gm(2020, 1, 1, 12, 1, 20, 134_000, 0)) do
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1m')
        ).to eq(DateTime.new(2019, 12, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('2m')
        ).to eq(DateTime.new(2019, 11, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('4m')
        ).to eq(DateTime.new(2019, 9, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('8m')
        ).to eq(DateTime.new(2019, 5, 1,
                             12, 1, 20, Rational(0, 24)))

        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1y')
        ).to eq(DateTime.new(2019, 1, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('12m')
        ).to eq(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1y')
        )
      end

      Timecop.freeze(Time.gm(2020, 4, 3, 0, 0, 0, 0, 0)) do
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1m')
        ).to eq(DateTime.new(2020, 3, 3,
                             0, 0, 0, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('2m')
        ).to eq(DateTime.new(2020, 2, 3,
                             0, 0, 0, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('4m')
        ).to eq(DateTime.new(2019, 12, 3,
                             0, 0, 0, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('8m')
        ).to eq(DateTime.new(2019, 8, 3,
                             0, 0, 0, Rational(0, 24)))

        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1y')
        ).to eq(DateTime.new(2019, 4, 3,
                             0, 0, 0, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('12m')
        ).to eq(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1y')
        )
      end
    end

    it 'test year parsing' do
      Timecop.freeze(Time.gm(2020, 1, 1, 12, 1, 20, 134_000, 0)) do
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('1y')
        ).to eq(DateTime.new(2019, 1, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('2y')
        ).to eq(DateTime.new(2018, 1, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('4y')
        ).to eq(DateTime.new(2016, 1, 1,
                             12, 1, 20, Rational(0, 24)))
        expect(
          FeatureFlagsPoller.relative_date_parse_for_feature_flag_matching('8y')
        ).to eq(DateTime.new(2012, 1, 1,
                             12, 1, 20, Rational(0, 24)))
      end
    end
  end

  describe 'consistency tests' do
    # These tests are the same across all libraries
    # See https://github.com/PostHog/posthog/blob/master/posthog/test/test_feature_flag.py#L627
    # where this test has directly been copied from.
    # They ensure that the server and library hash calculations are in sync.

    it 'is consistent for simple flags' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => '',
            'key' => 'simple-flag',
            'active' => true,
            'is_simple_flag' => false,
            'filters' => {
              'groups' => [{ 'properties' => [], 'rollout_percentage' => 45 }]
            }
          }
        ]
      }

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      # shouldn't call `/flags`
      stub_request(:post, flags_endpoint)
        .to_return(status: 400)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # This is the order of results we expect from the server
      # TODO: Extract this into a JSON file
      results = [ # rubocop:disable Metrics/CollectionLiteralLength
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        true,
        true,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        false,
        true,
        true,
        true,
        true,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        true,
        true,
        false,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        true,
        false,
        true,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        true,
        true,
        false,
        true,
        true,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
        true,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        false,
        true,
        false,
        true,
        true,
        false,
        false,
        true,
        true,
        true,
        false,
        true,
        false,
        false,
        true,
        true,
        false,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        false,
        true,
        true,
        true,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        false,
        true,
        false,
        false,
        true,
        false,
        true,
        true
      ]

      1000.times do |i|
        feature_flag_match = c.is_feature_enabled('simple-flag', "distinct_id_#{i}")
        expect(feature_flag_match).to eq results[i]
      end
    end

    it 'is consistent for multivariate flags' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'multivariate-flag',
            'is_simple_flag' => false,
            'active' => true,
            'filters' => {
              'groups' => [{ 'properties' => [], 'rollout_percentage' => 55 }],
              'multivariate' => {
                'variants' => [
                  { 'key' => 'first-variant', 'name' => 'First Variant', 'rollout_percentage' => 50 },
                  { 'key' => 'second-variant', 'name' => 'Second Variant', 'rollout_percentage' => 20 },
                  { 'key' => 'third-variant', 'name' => 'Third Variant', 'rollout_percentage' => 20 },
                  { 'key' => 'fourth-variant', 'name' => 'Fourth Variant', 'rollout_percentage' => 5 },
                  { 'key' => 'fifth-variant', 'name' => 'Fifth Variant', 'rollout_percentage' => 5 }
                ]
              }
            }
          }
        ]
      }

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      # shouldn't call `/flags`
      stub_request(:post, flags_endpoint)
        .to_return(status: 400)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # This is the order of results we expect from the server
      # TODO: Extract this into a JSON file
      results = [ # rubocop:disable Metrics/CollectionLiteralLength
        'second-variant',
        'second-variant',
        'first-variant',
        false,
        false,
        'second-variant',
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'third-variant',
        false,
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        false,
        'fourth-variant',
        'first-variant',
        false,
        'third-variant',
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'third-variant',
        false,
        'third-variant',
        'second-variant',
        'first-variant',
        false,
        'third-variant',
        false,
        false,
        'first-variant',
        'second-variant',
        false,
        'first-variant',
        'first-variant',
        'second-variant',
        false,
        'first-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        'second-variant',
        'second-variant',
        'third-variant',
        'second-variant',
        'first-variant',
        false,
        'first-variant',
        'second-variant',
        'fourth-variant',
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        'second-variant',
        false,
        'third-variant',
        false,
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        'fifth-variant',
        false,
        'second-variant',
        'first-variant',
        'second-variant',
        false,
        'third-variant',
        'third-variant',
        false,
        false,
        false,
        false,
        'third-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        'third-variant',
        'third-variant',
        false,
        'third-variant',
        'second-variant',
        'third-variant',
        false,
        false,
        'second-variant',
        'first-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        false,
        'second-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        'second-variant',
        'second-variant',
        false,
        'first-variant',
        false,
        false,
        false,
        'third-variant',
        'first-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        'fifth-variant',
        'second-variant',
        false,
        'second-variant',
        false,
        'first-variant',
        'third-variant',
        'first-variant',
        'fifth-variant',
        'third-variant',
        false,
        false,
        'fourth-variant',
        false,
        false,
        false,
        false,
        'third-variant',
        false,
        false,
        'third-variant',
        false,
        'first-variant',
        'second-variant',
        'second-variant',
        'second-variant',
        false,
        'first-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        false,
        false,
        false,
        'second-variant',
        false,
        false,
        'first-variant',
        false,
        'first-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'third-variant',
        'first-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        'third-variant',
        'third-variant',
        false,
        'second-variant',
        'first-variant',
        false,
        'second-variant',
        'first-variant',
        false,
        'first-variant',
        false,
        false,
        'first-variant',
        'fifth-variant',
        'first-variant',
        false,
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'second-variant',
        false,
        'second-variant',
        'third-variant',
        'third-variant',
        false,
        'first-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        false,
        'third-variant',
        'first-variant',
        false,
        'third-variant',
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        'second-variant',
        'second-variant',
        'first-variant',
        false,
        false,
        false,
        'second-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        'third-variant',
        false,
        'first-variant',
        false,
        'third-variant',
        false,
        'third-variant',
        'second-variant',
        'first-variant',
        false,
        false,
        'first-variant',
        'third-variant',
        'first-variant',
        'second-variant',
        'fifth-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        'third-variant',
        false,
        'second-variant',
        'first-variant',
        false,
        false,
        false,
        false,
        'third-variant',
        false,
        false,
        'third-variant',
        false,
        false,
        'first-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        'fourth-variant',
        'fourth-variant',
        'third-variant',
        'second-variant',
        'first-variant',
        'third-variant',
        'fifth-variant',
        false,
        'first-variant',
        'fifth-variant',
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'second-variant',
        'fifth-variant',
        'second-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        false,
        false,
        'third-variant',
        false,
        'second-variant',
        'fifth-variant',
        false,
        'third-variant',
        'first-variant',
        false,
        false,
        'fourth-variant',
        false,
        false,
        'second-variant',
        false,
        false,
        'first-variant',
        'fourth-variant',
        'first-variant',
        'second-variant',
        false,
        false,
        false,
        'first-variant',
        'third-variant',
        'third-variant',
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        false,
        'first-variant',
        'third-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        'second-variant',
        'second-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        'fifth-variant',
        'first-variant',
        false,
        false,
        false,
        'second-variant',
        'third-variant',
        'first-variant',
        'fourth-variant',
        'first-variant',
        'third-variant',
        false,
        'first-variant',
        'first-variant',
        false,
        'third-variant',
        'first-variant',
        'first-variant',
        'third-variant',
        false,
        'fourth-variant',
        'fifth-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        'first-variant',
        'second-variant',
        false,
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        false,
        'first-variant',
        false,
        'first-variant',
        false,
        false,
        false,
        'third-variant',
        'third-variant',
        'first-variant',
        false,
        false,
        'second-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'second-variant',
        'first-variant',
        false,
        'first-variant',
        'third-variant',
        false,
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'third-variant',
        'third-variant',
        false,
        false,
        false,
        false,
        'third-variant',
        'fourth-variant',
        'fourth-variant',
        'first-variant',
        'second-variant',
        false,
        'first-variant',
        false,
        'second-variant',
        'first-variant',
        'third-variant',
        false,
        'third-variant',
        false,
        'first-variant',
        'first-variant',
        'third-variant',
        false,
        false,
        false,
        'fourth-variant',
        'second-variant',
        'first-variant',
        false,
        false,
        'first-variant',
        'fourth-variant',
        false,
        'first-variant',
        'third-variant',
        'first-variant',
        false,
        false,
        'third-variant',
        false,
        'first-variant',
        false,
        'first-variant',
        'first-variant',
        'third-variant',
        'second-variant',
        'fourth-variant',
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        'second-variant',
        'first-variant',
        'second-variant',
        false,
        'first-variant',
        false,
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        'first-variant',
        'second-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'third-variant',
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        'fifth-variant',
        'fourth-variant',
        'first-variant',
        'second-variant',
        false,
        'fourth-variant',
        false,
        false,
        false,
        'fourth-variant',
        false,
        false,
        'third-variant',
        false,
        false,
        false,
        'first-variant',
        'third-variant',
        'third-variant',
        'second-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        'second-variant',
        false,
        false,
        'first-variant',
        false,
        'second-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'third-variant',
        'second-variant',
        false,
        false,
        'fifth-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'second-variant',
        'third-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        false,
        'third-variant',
        'first-variant',
        false,
        false,
        false,
        false,
        'fourth-variant',
        'first-variant',
        false,
        false,
        false,
        'third-variant',
        false,
        false,
        'second-variant',
        'first-variant',
        false,
        false,
        'second-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        'first-variant',
        false,
        false,
        'second-variant',
        'third-variant',
        'second-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        'first-variant',
        false,
        'second-variant',
        false,
        false,
        false,
        false,
        'first-variant',
        false,
        'third-variant',
        false,
        'first-variant',
        false,
        false,
        'second-variant',
        'third-variant',
        'second-variant',
        'fourth-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        false,
        'second-variant',
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        false,
        'second-variant',
        false,
        false,
        false,
        false,
        'second-variant',
        false,
        'first-variant',
        false,
        'third-variant',
        false,
        false,
        'first-variant',
        'third-variant',
        false,
        'third-variant',
        false,
        false,
        'second-variant',
        false,
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        'second-variant',
        false,
        false,
        'first-variant',
        'third-variant',
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        'second-variant',
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'fifth-variant',
        false,
        false,
        false,
        'first-variant',
        false,
        'third-variant',
        false,
        false,
        'second-variant',
        false,
        false,
        false,
        false,
        false,
        'fourth-variant',
        'second-variant',
        'first-variant',
        'second-variant',
        false,
        'second-variant',
        false,
        'second-variant',
        false,
        'first-variant',
        false,
        'first-variant',
        'first-variant',
        false,
        'second-variant',
        false,
        'first-variant',
        false,
        'fifth-variant',
        false,
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        false,
        'first-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        false,
        'fifth-variant',
        false,
        false,
        'third-variant',
        false,
        'third-variant',
        'first-variant',
        'first-variant',
        'third-variant',
        'third-variant',
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        'second-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        'fifth-variant',
        'first-variant',
        false,
        false,
        'fourth-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        'fourth-variant',
        'first-variant',
        false,
        'second-variant',
        'third-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        'third-variant',
        'third-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        'second-variant',
        false,
        false,
        'second-variant',
        false,
        'third-variant',
        'first-variant',
        'second-variant',
        'fifth-variant',
        'first-variant',
        'first-variant',
        false,
        'first-variant',
        'fifth-variant',
        false,
        false,
        false,
        'third-variant',
        'first-variant',
        'first-variant',
        'second-variant',
        'fourth-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        false,
        false,
        false,
        'second-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        'third-variant',
        false,
        'first-variant',
        false,
        'third-variant',
        'third-variant',
        'first-variant',
        'first-variant',
        false,
        'second-variant',
        false,
        'second-variant',
        'first-variant',
        false,
        false,
        false,
        'second-variant',
        false,
        'third-variant',
        false,
        'first-variant',
        'fifth-variant',
        'first-variant',
        'first-variant',
        false,
        false,
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'fourth-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'fifth-variant',
        false,
        false,
        false,
        'second-variant',
        false,
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        'second-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        'third-variant',
        'first-variant',
        false,
        'second-variant',
        false,
        false,
        'third-variant',
        'second-variant',
        'third-variant',
        false,
        'first-variant',
        'third-variant',
        'second-variant',
        'first-variant',
        'third-variant',
        false,
        false,
        'first-variant',
        'first-variant',
        false,
        false,
        false,
        'first-variant',
        'third-variant',
        'second-variant',
        'first-variant',
        'first-variant',
        'first-variant',
        false,
        'third-variant',
        'second-variant',
        'third-variant',
        false,
        false,
        'third-variant',
        'first-variant',
        false,
        'first-variant'
      ]

      1000.times do |i|
        feature_flag_match = c.get_feature_flag('multivariate-flag', "distinct_id_#{i}")

        if results[i]
          expect(feature_flag_match).to eq(results[i])
        else
          expect(feature_flag_match).to be false
        end
      end
    end
  end

  describe 'associated payloads' do
    it 'get all flags and payloads with fallback' do
      flag_res = [
        {
          'id' => 1,
          'name' => 'Beta Feature',
          'key' => 'beta-feature',
          'is_simple_flag' => false,
          'active' => true,
          'rollout_percentage' => 100,
          'filters' => {
            'groups' => [
              {
                'properties' => [],
                'rollout_percentage' => 100
              }
            ],
            'payloads' => {
              'true' => 'some-payload'
            }
          }
        },
        {
          'id' => 2,
          'name' => 'Beta Feature',
          'key' => 'disabled-feature',
          'is_simple_flag' => false,
          'active' => true,
          'filters' => {
            'groups' => [
              {
                'properties' => [],
                'rollout_percentage' => 0
              }
            ],
            'payloads' => {
              'true' => 'another-payload'
            }
          }
        },
        {
          'id' => 3,
          'name' => 'Beta Feature',
          'key' => 'beta-feature2',
          'is_simple_flag' => false,
          'active' => true,
          'filters' => {
            'groups' => [
              {
                'properties' => [{ 'key' => 'country', 'value' => 'US' }],
                'rollout_percentage' => 0
              }
            ],
            'payloads' => {
              'true' => 'payload-3'
            }
          }
        }
      ]

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { 'flags' => flag_res }.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: {
          'featureFlags' => { 'beta-feature' => 'variant-1', 'beta-feature2' => 'variant-2',
                              'disabled-feature' => false },
          'featureFlagPayloads' => { 'beta-feature' => 100, 'beta-feature2' => 300 }
        }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
      expect(c.get_all_flags_and_payloads('distinct_id')[:featureFlagPayloads]).to eq({ 'beta-feature' => 100,
                                                                                        'beta-feature2' => 300 })
      assert_requested :post, flags_endpoint, times: 1
    end

    it 'get all flags and payloads with fallback and empty local flags' do
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { 'flags' => [] }.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: {
          'featureFlags' => { 'beta-feature' => 'variant-1', 'beta-feature2' => 'variant-2' },
          'featureFlagPayloads' => { 'beta-feature' => 100, 'beta-feature2' => 300 }
        }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_all_flags_and_payloads('distinct_id')[:featureFlagPayloads]).to eq({ 'beta-feature' => 100,
                                                                                        'beta-feature2' => 300 })
      assert_requested :post, flags_endpoint, times: 1
    end

    it 'get all flags and payloads with fallback but only local eval is set' do
      flag_res = [
        {
          'id' => 1,
          'name' => 'Beta Feature',
          'key' => 'beta-feature',
          'is_simple_flag' => false,
          'active' => true,
          'rollout_percentage' => 100,
          'filters' => {
            'groups' => [
              {
                'properties' => [],
                'rollout_percentage' => 100
              }
            ],
            'payloads' => {
              'true' => 'some-payload'
            }
          }
        },
        {
          'id' => 2,
          'name' => 'Beta Feature',
          'key' => 'disabled-feature',
          'is_simple_flag' => false,
          'active' => true,
          'filters' => {
            'groups' => [
              {
                'properties' => [],
                'rollout_percentage' => 0
              }
            ],
            'payloads' => {
              'true' => 'another-payload'
            }
          }
        },
        {
          'id' => 3,
          'name' => 'Beta Feature',
          'key' => 'beta-feature2',
          'is_simple_flag' => false,
          'active' => true,
          'filters' => {
            'groups' => [
              {
                'properties' => [{ 'key' => 'country', 'value' => 'US' }],
                'rollout_percentage' => 0
              }
            ],
            'payloads' => {
              'true' => 'payload-3'
            }
          }
        }
      ]

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { 'flags' => flag_res }.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: {
          'featureFlags' => { 'beta-feature' => 'variant-1', 'beta-feature2' => 'variant-2' },
          'featureFlagPayloads' => { 'beta-feature' => 100, 'beta-feature2' => 300 }
        }.to_json)
      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_all_flags_and_payloads(
        'distinct_id',
        only_evaluate_locally: true
      )[:featureFlagPayloads]).to eq({ 'beta-feature' => 'some-payload' })
    end

    it 'get all flags and payloads with no fallback' do
      basic_flag = {
        'id' => 1,
        'name' => 'Beta Feature',
        'key' => 'beta-feature',
        'is_simple_flag' => false,
        'active' => true,
        'rollout_percentage' => 100,
        'filters' => {
          'groups' => [
            {
              'properties' => [],
              'rollout_percentage' => 100
            }
          ],
          'payloads' => {
            'true' => 'new'
          }
        }
      }
      disabled_flag = {
        'id' => 2,
        'name' => 'Beta Feature',
        'key' => 'disabled-feature',
        'is_simple_flag' => false,
        'active' => true,
        'filters' => {
          'groups' => [
            {
              'properties' => [],
              'rollout_percentage' => 0
            }
          ],
          'payloads' => {
            'true' => 'some-payload'
          }
        }
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { 'flags' => [basic_flag, disabled_flag] }.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: {
          'featureFlags' => { 'beta-feature' => 'variant-1', 'beta-feature2' => 'variant-2' }
        }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_all_flags_and_payloads('distinct_id')[:featureFlagPayloads]).to eq({ 'beta-feature' => 'new' })
      assert_not_requested :post, flags_endpoint
    end

    it 'evaluates boolean feature flags locally' do
      basic_flag_res = {
        'id' => 1,
        'name' => 'Beta Feature',
        'key' => 'person-flag',
        'is_simple_flag' => true,
        'active' => true,
        'filters' => {
          'groups' => [
            {
              'properties' => [
                {
                  'key' => 'region',
                  'operator' => 'exact',
                  'value' => ['USA'],
                  'type' => 'person'
                }
              ],
              'rollout_percentage' => 100
            }
          ],
          'payloads' => { 'true' => 300 }
        }
      }
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { 'flags' => [basic_flag_res] }.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => { 'person-flag' => 'person-flag-value' } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
      expect(c.get_feature_flag_payload('person-flag', 'some-distinct-id',
                                        person_properties: { 'region' => 'USA' })).to eq(300)
      expect(c.get_feature_flag_payload(
               'person-flag',
               'some-distinct-id',
               match_value: true,
               person_properties: { 'region' => 'USA' }
             )).to eq(300)
      assert_not_requested :post, flags_endpoint
    end

    it 'evaluates boolean feature flags with `/flags`' do
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { 'flags' => [] }.to_json)
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { 'featureFlags' => {},
                                        'featureFlagPayloads' => { 'person-flag' => 300 } }.to_json)
      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)
      expect(c.get_feature_flag_payload('person-flag', 'some-distinct-id',
                                        person_properties: { 'region' => 'USA' })).to eq(300)
      expect(c.get_feature_flag_payload(
               'person-flag',
               'some-distinct-id',
               match_value: true,
               person_properties: { 'region' => 'USA' }
             )).to eq(300)
      assert_requested :post, flags_endpoint, times: 2
    end

    it 'with multivariate feature flag payloads' do
      multivariate_flag = {
        id: 1,
        name: 'Beta Feature',
        key: 'beta-feature',
        is_simple_flag: false,
        active: true,
        rollout_percentage: 100,
        filters: {
          groups: [
            {
              properties: [
                { key: 'email', type: 'person', value: 'test@posthog.com', operator: 'exact' }
              ],
              rollout_percentage: 100,
              variant: 'second???'
            },
            { rollout_percentage: 50, variant: 'first??' }
          ],
          multivariate: {
            variants: [
              { key: 'first-variant', name: 'First Variant', rollout_percentage: 50 },
              { key: 'second-variant', name: 'Second Variant', rollout_percentage: 25 },
              { key: 'third-variant', name: 'Third Variant', rollout_percentage: 25 }
            ]
          },
          payloads: { 'first-variant' => 'some-payload', 'third-variant' => { 'a' => 'json' } }
        }
      }

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { flags: [multivariate_flag] }.to_json)
      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: { featureFlagPayloads: { 'first-variant' => { b: 'json' } } }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_feature_flag_payload(
               'beta-feature', 'test_id',
               person_properties: { email: 'test@posthog.com' }
             )).to eq({ a: 'json' })
      expect(c.get_feature_flag_payload(
               'beta-feature',
               'test_id',
               match_value: 'third-variant',
               person_properties: { email: 'test@posthog.com' }
             )).to eq({ a: 'json' })
      # Force different match value
      expect(c.get_feature_flag_payload(
               'beta-feature',
               'test_id',
               match_value: 'first-variant',
               person_properties: { email: 'test@posthog.com' }
             )).to eq('some-payload')
      assert_not_requested :post, flags_endpoint
    end

    it 'with decrypted feature flag payloads' do
      encrypted_payload_flag_key = 'my_secret_key'
      mock_decrypted_payload = '"super secret payload in plaintext"'
      stub_request(
        :get,
        "https://app.posthog.com/api/projects/@current/feature_flags/#{encrypted_payload_flag_key}/remote_config?token=testsecret"
      ).to_return(status: 200, body: mock_decrypted_payload)
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { flags: [] }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_remote_config_payload(encrypted_payload_flag_key))
      assert_not_requested :post, flags_endpoint
    end

    it 'handles quota limited response by unsetting all flags' do
      flag_res = [
        {
          'id' => 1,
          'name' => 'Beta Feature',
          'key' => 'beta-feature',
          'is_simple_flag' => false,
          'active' => true,
          'rollout_percentage' => 100,
          'filters' => {
            'groups' => [
              {
                'properties' => [{ 'key' => 'country', 'value' => 'US' }],
                'rollout_percentage' => 0
              }
            ],
            'payloads' => {
              'true' => 'payload-1'
            }
          }
        }
      ]

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: { 'flags' => flag_res }.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 200, body: {
          'featureFlags' => { 'beta-feature' => true, 'other-flag' => false },
          'featureFlagPayloads' => { 'beta-feature' => 'some-payload' },
          'quotaLimited' => ['feature_flags']
        }.to_json)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      result = c.get_all_flags_and_payloads('distinct_id')
      expect(result[:featureFlags]).to eq({})
      expect(result[:featureFlagPayloads]).to eq({})
      assert_requested :post, flags_endpoint, times: 1
    end
  end

  describe 'resiliency' do
    it 'does not override existing feature flags on local evaluation error' do
      api_feature_flag_res = {
        'flags' => [
          {
            'id' => 1,
            'name' => 'Beta Feature',
            'key' => 'person-flag',
            'is_simple_flag' => true,
            'active' => true,
            'filters' => {
              'groups' => [
                {
                  'properties' => [
                    {
                      'key' => 'region',
                      'operator' => 'exact',
                      'value' => ['USA'],
                      'type' => 'person'
                    }
                  ],
                  'rollout_percentage' => 100
                }
              ]
            }
          }
        ]
      }

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      stub_request(:post, flags_endpoint)
        .to_return(status: 400)

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      expect(c.get_feature_flag('person-flag', 'distinct_id', person_properties: { 'region' => 'USA' })).to eq(true)

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 400, body: { 'error' => 'went_wrong!' }.to_json)

      # force reload to simulate poll interval
      c.reload_feature_flags

      expect(c.get_feature_flag('person-flag', 'distinct_id', person_properties: { 'region' => 'USA' })).to eq(true)
      assert_not_requested :post, flags_endpoint
    end

    it 'clears all flags when hitting quota limits (402 response)' do
      # First load flags successfully
      api_feature_flag_res = {
        flags: [
          {
            id: 1,
            name: 'Beta Feature',
            key: 'person-flag',
            is_simple_flag: true,
            active: true,
            filters: {
              groups: [
                {
                  properties: [
                    {
                      key: 'region',
                      operator: 'exact',
                      value: ['USA'],
                      type: 'person'
                    }
                  ],
                  rollout_percentage: 100
                }
              ]
            }
          }
        ]
      }

      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 200, body: api_feature_flag_res.to_json)

      # Add the exact stub for the `/flags` endpoint as recommended in the error
      stub_request(:post, 'https://app.posthog.com/flags/?v=2').with(
        body: '{"distinct_id":"distinct_id","groups":{},"person_properties":{"distinct_id":"distinct_id","region":"USA"},"group_properties":{},"token":"testsecret"}', # rubocop:disable Layout/LineLength
        headers: {
          'Accept' => '*/*',
          'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
          'Content-Type' => 'application/json',
          'Host' => 'app.posthog.com',
          'User-Agent' => "posthog-ruby#{PostHog::VERSION}"
        }
      ).to_return(status: 200, body: '{"featureFlags": {}}', headers: {})

      c = Client.new(api_key: API_KEY, personal_api_key: API_KEY, test_mode: true)

      # Initial flag check should succeed
      expect(c.get_feature_flag('person-flag', 'distinct_id', person_properties: { region: 'USA' })).to eq(true)

      # Now simulate quota limit with 402 response
      stub_request(
        :get,
        'https://app.posthog.com/api/feature_flag/local_evaluation?token=testsecret&send_cohorts=true'
      ).to_return(status: 402, body: { error: 'quota_limit_exceeded' }.to_json)

      # Force reload to simulate poll interval
      c.reload_feature_flags

      # After quota limit, flag should return false (cleared)
      expect(c.get_feature_flag('person-flag', 'distinct_id', person_properties: { region: 'USA' })).to eq(false)
    end
  end
end
