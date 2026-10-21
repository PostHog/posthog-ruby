# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PostHog::FeatureFlagsPoller, 'null string operators' do
  [
    ['icontains', 'nul', true],
    ['icontains', 'x', false],
    ['not_icontains', 'x', true],
    ['not_icontains', 'nul', false],
    ['starts_with', 'NU', true],
    ['starts_with', 'x', false],
    ['not_starts_with', 'x', true],
    ['not_starts_with', 'nu', false],
    ['ends_with', 'LL', true],
    ['ends_with', 'x', false],
    ['not_ends_with', 'x', true],
    ['not_ends_with', 'll', false],
    ['regex', '^nu', true],
    ['regex', '^NULL$', false],
    ['regex', '^$', false],
    ['regex', 'x', false],
    ['not_regex', 'x', true],
    ['not_regex', '^nu', false],
    ['not_regex', '^$', true],
    ['regex', '[', false],
    ['not_regex', '[', false]
  ].each do |operator, filter, expected|
    it "matches explicit nil with #{operator} pattern #{filter.inspect}" do
      property = { key: 'value', value: filter, operator: operator }
      expect(described_class.match_property(property, { value: nil })).to be(expected)
    end
  end

  %w[icontains not_icontains starts_with not_starts_with ends_with not_ends_with regex not_regex].each do |operator|
    it "keeps missing properties inconclusive with #{operator}" do
      property = { key: 'value', value: 'x', operator: operator }
      expect { described_class.match_property(property, {}) }.to raise_error(PostHog::InconclusiveMatchError)
    end
  end
end
