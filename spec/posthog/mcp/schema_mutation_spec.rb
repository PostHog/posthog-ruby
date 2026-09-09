# frozen_string_literal: true

# rubocop:disable Layout/LineLength

require_relative 'spec_helper'

RSpec.describe PostHog::MCP::SchemaMutation do
  let(:schema) { { type: 'object', properties: { x: { type: 'string' } }, required: ['x'] } }

  it 'adds a required context parameter on a new hash without touching the input' do
    out = described_class.add_context_parameter(schema, tool_name: 't')
    expect(out[:properties].keys).to eq(%i[x context])
    expect(out[:properties][:context][:description]).to eq(PostHog::MCP::DEFAULT_CONTEXT_PARAMETER_DESCRIPTION)
    expect(out[:required]).to eq(%w[x context])
    expect(schema[:properties].keys).to eq([:x])
    expect(schema[:required]).to eq(['x'])
  end

  it 'honours description overrides and removes additionalProperties: false' do
    out = described_class.add_context_parameter({ 'type' => 'object', 'properties' => {}, 'additionalProperties' => false },
                                                tool_name: 't', description: 'why')
    expect(out).to eq('type' => 'object', 'properties' => { 'context' => { type: 'string', description: 'why' } },
                      'required' => ['context'])
  end

  it 'skips schemas that declare the param or are composed, and builds one from nil' do
    owned = { type: 'object', properties: { context: { type: 'string' } } }
    expect(described_class.add_context_parameter(owned, tool_name: 't')).to equal(owned)
    complex = { oneOf: [{ type: 'object' }] }
    expect(described_class.add_context_parameter(complex, tool_name: 't')).to equal(complex)
    out = described_class.add_conversation_id_parameter(nil, tool_name: 't')
    expect(out[:properties][:conversation_id][:description]).to eq(PostHog::MCP::DEFAULT_CONVERSATION_ID_DESCRIPTION)
    expect(out[:required]).to eq([])
  end

  it 'adds the model parameter with the JS default description' do
    out = described_class.add_model_parameter(schema, tool_name: 't')
    expect(out[:properties][:llm_model][:description]).to eq(PostHog::MCP::DEFAULT_MODEL_PARAMETER_DESCRIPTION)
    expect(out[:required]).to include('llm_model')
  end

  describe '.add_output_instructions' do
    it 'declares an optional _mcp_instructions property' do
      out, declared = described_class.add_output_instructions({ type: 'object', properties: { total: { type: 'integer' } },
                                                                required: ['total'] }, tool_name: 't')
      expect(declared).to be(true)
      expect(out[:properties][:_mcp_instructions]).to eq(
        type: 'object', description: 'Server-issued metadata for this conversation.',
        properties: { conversation_id: { type: 'string', description: 'The server-issued conversation identifier.' } }
      )
      expect(out[:required]).to eq(['total'])
    end

    it 'recognises its own earlier declaration, leaves customer keys alone, and skips complex schemas' do
      ours, = described_class.add_output_instructions({ type: 'object', properties: {} }, tool_name: 't')
      expect(described_class.add_output_instructions(ours, tool_name: 't')).to eq([ours, true])
      theirs = { type: 'object', properties: { _mcp_instructions: { type: 'string' } } }
      expect(described_class.add_output_instructions(theirs, tool_name: 't')).to eq([theirs, false])
      complex = { '$ref': '#/x' }
      expect(described_class.add_output_instructions(complex, tool_name: 't')).to eq([complex, false])
      expect(described_class.add_output_instructions(nil, tool_name: 't')).to eq([nil, false])
    end
  end
end
# rubocop:enable Layout/LineLength
