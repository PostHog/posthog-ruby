# frozen_string_literal: true

require 'spec_helper'

# The flags service doesn't resolve a flag dependency inside a cohort. A flag_evaluates_to leaf never
# matches there, so `negation` turns it into a match. Any other operator compares the leaf's key with
# person properties.
RSpec.describe PostHog::FeatureFlagsPoller, 'flag leaves in cohorts' do
  let(:poller) { described_class.new(60, nil, API_KEY, 'https://us.i.posthog.com', 3) }

  after { poller.shutdown_poller }

  def dependency_leaf(**overrides)
    { key: 'parent', type: 'flag', operator: 'flag_evaluates_to', value: true, dependency_chain: ['parent'] }
      .merge(overrides)
  end

  def evaluate(leaf, person_properties = {})
    poller._apply_flag_definitions(
      flags: [
        { key: 'parent', active: true, filters: { groups: [{ properties: [], rollout_percentage: 100 }] } },
        { key: 'child', active: true,
          filters: { groups: [{ properties: [{ key: 'id', type: 'cohort', value: 1 }], rollout_percentage: 100 }] } }
      ],
      cohorts: { '1' => { type: 'OR', values: [{ type: 'AND', values: [leaf] }] } }
    )
    poller.get_feature_flag('child', 'user-1', {}, person_properties, {}, true)[0]
  end

  it 'never matches a flag_evaluates_to leaf, whatever the referenced flag returns' do
    expect(evaluate(dependency_leaf)).to be(false)
    expect(evaluate(dependency_leaf(value: false))).to be(false)
    expect(evaluate(dependency_leaf, { 'parent' => true })).to be(false)
  end

  it 'applies negation to the non-match' do
    expect(evaluate(dependency_leaf(negation: true))).to be(true)
  end

  it 'decides a flag_evaluates_to leaf without a value or chain' do
    leaf = dependency_leaf
    leaf.delete(:value)
    leaf.delete(:dependency_chain)
    expect(evaluate(leaf)).to be(false)
  end

  it 'matches a leaf with another operator against person properties' do
    leaf = { key: 'parent', type: 'flag', operator: 'exact', value: true }
    expect(evaluate(leaf, { 'parent' => true })).to be(true)
    expect(evaluate(leaf, { 'parent' => false })).to be(false)
    expect(evaluate(leaf)).to be_nil
  end

  it 'does not report a flag_evaluates_to leaf as an unsupported definition' do
    cohorts = { '1' => { 'type' => 'OR', 'values' => [{ 'type' => 'AND', 'values' => [dependency_leaf] }] } }
    unsupported = described_class.send(:unsupported_property?, { key: 'id', type: 'cohort', value: 1 }, {}, cohorts,
                                       Set.new)
    expect(unsupported).to be(false)
  end
end
