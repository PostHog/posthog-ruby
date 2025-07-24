# frozen_string_literal: true

require 'spec_helper'

describe PostHog::SendFeatureFlagsOptions do
  describe '#initialize' do
    it 'creates with no parameters' do
      options = PostHog::SendFeatureFlagsOptions.new
      expect(options.only_evaluate_locally).to be_nil
      expect(options.person_properties).to eq({})
      expect(options.group_properties).to eq({})
    end

    it 'creates with all parameters' do
      options = PostHog::SendFeatureFlagsOptions.new(
        only_evaluate_locally: true,
        person_properties: { plan: 'premium' },
        group_properties: { company: { industry: 'tech' } }
      )
      expect(options.only_evaluate_locally).to eq(true)
      expect(options.person_properties).to eq({ plan: 'premium' })
      expect(options.group_properties).to eq({ company: { industry: 'tech' } })
    end

    it 'creates with nil values' do
      options = PostHog::SendFeatureFlagsOptions.new(
        only_evaluate_locally: nil,
        person_properties: nil,
        group_properties: nil
      )
      expect(options.only_evaluate_locally).to be_nil
      expect(options.person_properties).to eq({})
      expect(options.group_properties).to eq({})
    end
  end

  describe '#to_h' do
    it 'converts to hash' do
      options = PostHog::SendFeatureFlagsOptions.new(
        only_evaluate_locally: true,
        person_properties: { plan: 'premium' },
        group_properties: { company: { industry: 'tech' } }
      )
      hash = options.to_h
      expect(hash).to eq(
        only_evaluate_locally: true,
        person_properties: { plan: 'premium' },
        group_properties: { company: { industry: 'tech' } }
      )
    end
  end

  describe '.from_hash' do
    it 'creates from hash with symbol keys' do
      hash = {
        only_evaluate_locally: true,
        person_properties: { plan: 'premium' },
        group_properties: { company: { industry: 'tech' } }
      }
      options = PostHog::SendFeatureFlagsOptions.from_hash(hash)
      expect(options.only_evaluate_locally).to eq(true)
      expect(options.person_properties).to eq({ plan: 'premium' })
      expect(options.group_properties).to eq({ company: { industry: 'tech' } })
    end

    it 'creates from hash with string keys' do
      hash = {
        'only_evaluate_locally' => true,
        'person_properties' => { 'plan' => 'premium' },
        'group_properties' => { 'company' => { 'industry' => 'tech' } }
      }
      options = PostHog::SendFeatureFlagsOptions.from_hash(hash)
      expect(options.only_evaluate_locally).to eq(true)
      expect(options.person_properties).to eq({ 'plan' => 'premium' })
      expect(options.group_properties).to eq({ 'company' => { 'industry' => 'tech' } })
    end

    it 'creates from partial hash' do
      hash = { person_properties: { plan: 'premium' } }
      options = PostHog::SendFeatureFlagsOptions.from_hash(hash)
      expect(options.only_evaluate_locally).to be_nil
      expect(options.person_properties).to eq({ plan: 'premium' })
      expect(options.group_properties).to eq({})
    end

    it 'returns nil for non-hash input' do
      expect(PostHog::SendFeatureFlagsOptions.from_hash('not a hash')).to be_nil
      expect(PostHog::SendFeatureFlagsOptions.from_hash(nil)).to be_nil
      expect(PostHog::SendFeatureFlagsOptions.from_hash(123)).to be_nil
    end

    it 'creates from empty hash' do
      options = PostHog::SendFeatureFlagsOptions.from_hash({})
      expect(options.only_evaluate_locally).to be_nil
      expect(options.person_properties).to eq({})
      expect(options.group_properties).to eq({})
    end

    it 'handles explicit false value correctly with symbol key' do
      hash = { only_evaluate_locally: false, 'only_evaluate_locally' => true }
      options = PostHog::SendFeatureFlagsOptions.from_hash(hash)
      expect(options.only_evaluate_locally).to eq(false)
    end

    it 'handles explicit false value correctly with string key' do
      hash = { 'only_evaluate_locally' => false }
      options = PostHog::SendFeatureFlagsOptions.from_hash(hash)
      expect(options.only_evaluate_locally).to eq(false)
    end

    it 'handles explicit nil value correctly' do
      hash = { only_evaluate_locally: nil, 'only_evaluate_locally' => true }
      options = PostHog::SendFeatureFlagsOptions.from_hash(hash)
      expect(options.only_evaluate_locally).to be_nil
    end
  end
end
