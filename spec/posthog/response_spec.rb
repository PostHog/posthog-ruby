# frozen_string_literal: true

require 'spec_helper'

module PostHog
  describe Response do
    describe '#status' do
      it { expect(subject).to respond_to(:status) }
    end

    describe '#error' do
      it { expect(subject).to respond_to(:error) }
    end

    describe '#initialize' do
      let(:status) { 404 }
      let(:error) { 'Oh No' }

      subject { described_class.new(status, error) }

      it 'exposes the supplied status' do
        expect(subject.status).to eq(status)
      end

      it 'exposes the supplied error' do
        expect(subject.error).to eq(error)
      end
    end
  end
end
