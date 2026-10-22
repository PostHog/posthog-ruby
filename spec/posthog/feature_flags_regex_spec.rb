# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PostHog::FeatureFlagsPoller, 'regex compatibility' do
  %w[regex not_regex].each do |operator|
    describe operator do
      [
        ['Unicode digits', '\\d+', '١'],
        ['astral digits', '\\d+', '𝟙'],
        ['Unicode word characters', '\\w+', 'é'],
        ['Unicode whitespace', '\\s', "\u00a0"],
        ['complement shorthand', '\\D', '١'],
        ['class shorthand', '[\\w]', 'é'],
        ['trailing newline', '^foo$', "foo\n"],
        ['internal line anchors', '^foo$', "bar\nfoo\nbaz"],
        ['start anchor alone', '^foo', "bar\nfoo"],
        ['end anchor alone', 'foo$', "foo\nbar"],
        ['POSIX class', '[[:alpha:]]', 'é'],
        ['variable lookbehind', '(?<=a+)b', 'aab'],
        ['identity escape', '\\q', 'q'],
        ['inline flags', '(?i)null', 'NULL'],
        ['Unicode property', '\\p{L}', 'é'],
        ['class intersection', '[a&&b]', 'a'],
        ['class difference', '[a-z--b]', 'b'],
        ['class symmetric difference', '[a~~b]', '~'],
        ['class identity punctuation', '[\\@]', '@'],
        ['class non-boundary', '[\\B]', 'B'],
        ['word-boundary budget', '.*\\bbot\\b.*', 'a' * 140],
        ['non-word-boundary budget', '.*\\Bbot\\B.*', 'a' * 140],
        ['quantified start anchor', '^?https?://', 'https://a'],
        ['quantified end anchor', '$?', 'x'],
        ['empty noncapturing repetition', '(?:)*', 'x'],
        ['leading repetition', '{2}', 'x'],
        ['alternation leading repetition', 'a|{2}', 'x'],
        ['group leading repetition', '(?:{2})', 'x'],
        ['open repetition', 'a{,2}', 'aa'],
        ['stacked repetition', 'a*{2}', 'aa'],
        ['nested star repetition', 'a**', 'x'],
        ['nested plus repetition', 'a+*', 'x'],
        ['nested optional repetition', 'a?*', 'x'],
        ['nested lazy repetition', 'a*??', 'x'],
        ['nested lazy optional', 'a???', 'x'],
        ['nested lazy star', 'a??*', 'x'],
        ['nested bounded repetition', 'a{2}*', 'x'],
        ['optional fixed repetition', 'a{2}?', 'x'],
        ['oversized repetition', 'a{0,4294967296}', 'x'],
        ['native repetition limit', 'a{100001}', 'x'],
        ['execution encoding failure', '.', "\xff".b.force_encoding('UTF-8')],
        ['backreference', '(a)\\1', 'aa'],
        ['lookahead', 'a(?=b)', 'ab'],
        ['possessive repetition', 'a++', 'aa']
      ].each do |name, pattern, input|
        it "defers #{name} without returning a definitive #{operator} result" do
          expect do
            described_class.match_property({ key: 'value', operator: operator, value: pattern }, { value: input })
          end.to raise_error(PostHog::InconclusiveMatchError)
        end
      end

      [
        ['plain search', 'pro', 'a pro plan', true],
        ['anchors', '^pro$', 'a pro plan', false],
        ['case-sensitive search', '^pro$', 'PRO', false],
        ['ASCII digits', '^\\d+$', '123', true],
        ['ASCII email', '^[\\w.+-]+@example\\.com$', 'a.b+tag@example.com', true],
        ['grouped repetition', '^(?:ab|cd){2,3}$', 'abcdab', true],
        ['lazy star', 'a*?', 'x', true],
        ['lazy plus', 'a+?', 'x', false],
        ['lazy optional', 'a??', 'x', true],
        ['escaped marker', '^\\\\p\\{L\\}$', '\\p{L}', true],
        ['hexadecimal byte', '^\\x41+$', 'AA', true],
        ['class backspace', '[\\b]', "\b", true],
        ['escaped punctuation', '^a\\-b\\@c\\:d\\_e\\=f\\ g$', 'a-b@c:d_e=f g', true],
        ['escaped class punctuation', '[\\-\\]\\[]+', '-][', true],
        ['literal assertion punctuation', '^\\^?\\${2}\\({2}\\|{2}$', '$$((||', true],
        ['class anchors', '^[\\^$?]+$', '$?^', true],
        ['class anchors with newline input', '[\\^$?]+', "$?^\n", true],
        ['escaped anchors with newline input', '\\^\\$', "^$\n", true],
        ['class trailing hyphen', '^[\\w-]+$', 'a-b', true],
        ['scalar dot', '^.$', '😀', true],
        ['carriage-return dot', '^.$', "\r", true],
        ['Unicode literal', '^😀?$', '', true],
        ['Unicode literal search', 'é', 'café', true],
        ['absolute anchors', '\\Afoo\\z', "foo\n", false],
        ['empty Unicode input', '', 'é', true],
        ['empty newline input', '', "\n", true],
        ['explicit null', '^null$', nil, true],
        ['existing array stringification', '\\[1, 2\\]', [1, 2], true]
      ].each do |name, pattern, input, expected|
        it "keeps #{name} local" do
          expect(described_class.match_property({ key: 'value', operator: operator, value: pattern }, { value: input }))
            .to eq(operator == 'regex' ? expected : !expected)
        end
      end

      ['[', '(', '*', '?*'].each do |pattern|
        ['value', 'é', nil].each do |input|
          it "returns false for invalid portable syntax #{pattern.inspect} and #{input.inspect}" do
            expect(described_class.match_property({ key: 'value', operator: operator, value: pattern },
                                                  { value: input }))
              .to be(false)
          end
        end
      end

      it 'keeps a missing property inconclusive' do
        expect do
          described_class.match_property({ key: 'value', operator: operator, value: '' }, {})
        end.to raise_error(PostHog::InconclusiveMatchError)
      end

      it 'does not turn unsupported regex into a match through cohort negation' do
        leaf = { key: 'value', type: 'person', operator: operator, value: '\\q', negation: true }
        expect do
          described_class.match_property_group({ type: 'AND', values: [leaf] }, { value: 'q' }, {})
        end.to raise_error(PostHog::InconclusiveMatchError)
      end
    end
  end

  describe 'public fallback gates' do
    let(:client) { PostHog::Client.new(api_key: API_KEY, test_mode: true) }
    let(:poller) { client.instance_variable_get(:@feature_flags_poller) }

    after { client.shutdown }

    %w[regex not_regex].each do |operator|
      [
        ['unsupported syntax', '\\q', { value: 'q' }, true],
        ['unsupported Unicode shorthand', '\\w+', { value: 'é' }, true],
        ['missing property control', 'safe', {}, true],
        ['portable match', 'safe', { value: 'safe' }, false],
        ['portable no-match', 'safe', { value: 'other' }, false],
        ['invalid syntax', '[', { value: 'safe' }, false]
      ].each do |name, pattern, properties, fallback|
        it "#{fallback ? 'uses remote fallback' : 'stays local'} for #{operator} #{name} in both callers" do
          property = { key: 'value', operator: operator, value: pattern, type: 'person' }
          flag = { id: 1, key: 'regex-flag', active: true,
                   filters: { groups: [{ properties: [property], rollout_percentage: 100 }] } }
          poller._apply_flag_definitions(flags: [flag], group_type_mapping: {}, cohorts: {})
          allow(poller).to receive(:load_feature_flags)
          remote_flag = PostHog::FeatureFlag.from_value_and_payload('regex-flag', 'remote', nil)
          remote = { flags: { 'regex-flag' => remote_flag }, featureFlags: { 'regex-flag' => 'remote' },
                     featureFlagPayloads: {} }
          allow(poller).to receive(:get_flags).and_return(remote)
          options = { person_properties: properties }
          expected = if fallback
                       'remote'
                     elsif pattern == '['
                       false
                     else
                       operator == 'regex' ? name == 'portable match' : name != 'portable match'
                     end
          snapshot = client.evaluate_flags('user', **options, flag_keys: ['regex-flag'])
          legacy = client.get_feature_flag('regex-flag', 'user', **options, send_feature_flag_events: false)
          expect(snapshot.get_flag('regex-flag')).to eq(expected)
          expect(legacy).to eq(expected)
          if fallback
            expect(poller).to have_received(:get_flags).twice
            expect(client.evaluate_flags('user', **options, flag_keys: ['regex-flag'], only_evaluate_locally: true)
                         .get_flag('regex-flag')).to be_nil
            local_options = options.merge(only_evaluate_locally: true, send_feature_flag_events: false)
            expect(client.get_feature_flag('regex-flag', 'user', **local_options)).to be_nil
            expect(poller).to have_received(:get_flags).twice
          else
            expect(poller).not_to have_received(:get_flags)
          end
        end
      end
    end
  end
end
