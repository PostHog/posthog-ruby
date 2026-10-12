# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PostHog::FeatureFlagsPoller, 'experiment holdouts' do
  let(:poller) { described_class.new(60, nil, API_KEY, 'https://us.i.posthog.com', 3) }

  after { poller.shutdown_poller }

  # An active multivariate flag whose only release condition matches everyone and
  # forces "control", so any result other than "control" or false comes from the
  # holdout rather than from ordinary assignment.
  def flag(holdout, key: 'checkout', **overrides)
    filters = {
      groups: [{ properties: [], rollout_percentage: 100, variant: 'control' }],
      multivariate: { variants: [{ key: 'control', rollout_percentage: 50 },
                                 { key: 'test', rollout_percentage: 50 }] }
    }
    filters[:holdout] = holdout unless holdout.nil?
    { key: key, active: true, filters: filters }.merge(overrides)
  end

  def evaluate(flags, distinct_id: 'user-1', key: 'checkout', groups: {}, group_type_mapping: {})
    poller._apply_flag_definitions({ flags: flags.is_a?(Array) ? flags : [flags],
                                     group_type_mapping: group_type_mapping, cohorts: {} })
    poller.get_feature_flag(key, distinct_id, groups, {}, {}, true)[0]
  end

  describe 'membership bucketing' do
    # The server hashes `holdout-<bucketing value>` with no flag key, holdout id or
    # salt. The dot-separated flag hash selects a different population, so these
    # vectors pin the input the hash is computed over.
    {
      'user-1' => 0.17805599206573022,
      'user-5' => 0.6563813925994418
    }.each do |bucketing_value, expected|
      it "hashes #{bucketing_value} the way the server does" do
        expect(poller.send(:_holdout_hash, bucketing_value)).to be_within(1e-9).of(expected)
      end
    end

    it 'holds out an identifier inside the percentage and lets the others through' do
      definition = flag({ id: 727, exclusion_percentage: 20 })
      expect(evaluate(definition, distinct_id: 'user-1')).to eq('holdout-727')
      expect(evaluate(definition, distinct_id: 'user-5')).to eq('control')
    end

    it 'compares inclusively and clamps the percentage without truncating fractions' do
      allow(poller).to receive(:_holdout_hash).and_return(0.125)

      [[12.5, 'holdout-727'], [12.4, 'control'], [0, 'control'], [-10, 'control']].each do |percentage, expected|
        expect(evaluate(flag({ id: 727, exclusion_percentage: percentage }))).to eq(expected)
      end
    end

    [100, 150].each do |percentage|
      it "holds everyone out at #{percentage} without computing a hash" do
        expect(poller).not_to receive(:_holdout_hash)
        expect(evaluate(flag({ id: 727, exclusion_percentage: percentage }))).to eq('holdout-727')
      end
    end

    it 'uses the flag-level group key rather than the distinct id' do
      definition = flag({ id: 727, exclusion_percentage: 20 })
      definition[:filters][:aggregation_group_type_index] = 0

      result = evaluate(definition, distinct_id: 'user-5', groups: { company: 'user-1' },
                                    group_type_mapping: { '0' => 'company' })
      expect(result).to eq('holdout-727')
    end
  end

  describe 'precedence' do
    it 'wins over release conditions and a condition variant override' do
      definition = flag({ id: 727, exclusion_percentage: 100 })
      definition[:filters][:groups] = [{
        properties: [{ key: 'region', value: 'USA', operator: 'exact', type: 'person' }],
        rollout_percentage: 0,
        variant: 'test'
      }]

      expect(evaluate(definition)).to eq('holdout-727')
    end

    it 'does not enable an inactive flag' do
      definition = flag({ id: 727, exclusion_percentage: 100 }, active: false)
      expect(evaluate(definition)).to be false
    end

    it 'leaves ordinary assignment alone when there is no holdout' do
      expect(evaluate(flag(nil))).to eq('control')
    end

    [{ id: nil, exclusion_percentage: 100 }, { exclusion_percentage: 100 },
     { id: 727, exclusion_percentage: nil }, { id: 727 }, {}].each do |holdout|
      it "skips the incomplete holdout #{holdout.inspect} and assigns normally" do
        expect(evaluate(flag(holdout))).to eq('control')
      end
    end
  end

  describe 'bulk and dependency evaluation' do
    it 'resolves the holdout once and compares dependencies against that value' do
      dependent = flag(nil, key: 'dependent')
      dependent[:filters][:groups] = [{
        properties: [{ key: 'checkout', value: 'holdout-727', operator: 'flag_evaluates_to', type: 'flag',
                       dependency_chain: ['checkout'] }],
        rollout_percentage: 100,
        variant: 'control'
      }]
      definitions = [flag({ id: 727, exclusion_percentage: 100 }), dependent]
      poller._apply_flag_definitions({ flags: definitions, group_type_mapping: {}, cohorts: {} })

      flags = poller.get_all_flags_and_payloads('user-1', {}, {}, {}, true)[:featureFlags]
      expect(flags).to eq({ 'checkout' => 'holdout-727', 'dependent' => 'control' })
    end
  end
end
