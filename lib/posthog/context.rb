# frozen_string_literal: true

module PostHog
  # Request/fiber-local context applied to capture calls.
  #
  # The context is stored using Thread.current[], which is fiber-local on
  # supported Ruby versions. This keeps request-scoped data isolated across
  # concurrent threads/fibers when callers wrap work in {with_context}.
  class Context
    STORAGE_KEY = :posthog_context

    attr_accessor :distinct_id, :session_id, :properties

    def initialize(distinct_id: nil, session_id: nil, properties: {})
      @distinct_id = distinct_id
      @session_id = session_id
      @properties = properties ? properties.dup : {}
      apply_session_property!
    end

    def self.current
      Thread.current[STORAGE_KEY]
    end

    def self.current=(context)
      Thread.current[STORAGE_KEY] = context
    end

    def self.with_context(data = nil, fresh: false, **kwargs)
      raise ArgumentError, 'with_context requires a block' unless block_given?

      previous_context = current
      self.current = resolve(merge_data_and_kwargs(data, kwargs), previous_context, fresh: fresh)
      yield
    ensure
      self.current = previous_context
    end

    def self.enter_context(data = nil, fresh: false, **kwargs)
      self.current = resolve(merge_data_and_kwargs(data, kwargs), current, fresh: fresh)
    end

    def self.get_context
      current&.to_h
    end

    def self.identify_context(distinct_id)
      return unless current

      current.distinct_id = distinct_id
    end

    def self.set_context_session(session_id)
      return unless current

      current.session_id = session_id
      current.apply_session_property!
    end

    def self.tag_context(key_or_properties, value = nil)
      return unless current

      if key_or_properties.is_a?(Hash)
        current.properties = merge_properties(current.properties, key_or_properties)
      else
        current.properties[key_or_properties] = value
      end
    end

    def self.resolve(data, parent, fresh: false)
      data = normalize_data(data)

      parent_properties = fresh || parent.nil? ? {} : parent.properties
      properties = merge_properties(parent_properties, data[:properties] || {})

      new(
        distinct_id: data[:distinct_id] || (fresh || parent.nil? ? nil : parent.distinct_id),
        session_id: data[:session_id] || (fresh || parent.nil? ? nil : parent.session_id),
        properties: properties
      )
    end

    def self.merge_data_and_kwargs(data, kwargs)
      data ||= {}
      raise ArgumentError, 'context data must be a Hash' unless data.is_a?(Hash)

      data.merge(kwargs)
    end

    def self.merge_properties(base, overrides)
      merged = (base || {}).dup
      (overrides || {}).each do |key, value|
        merged.delete(key.to_s) if key.is_a?(Symbol)
        merged.delete(key.to_sym) if key.is_a?(String)
        merged[key] = value
      end
      merged
    end

    def self.normalize_data(data)
      data ||= {}
      raise ArgumentError, 'context data must be a Hash' unless data.is_a?(Hash)

      properties = data[:properties] || data['properties'] || {}
      raise ArgumentError, 'context properties must be a Hash' unless properties.is_a?(Hash)

      {
        distinct_id: data[:distinct_id] || data['distinct_id'] || data[:distinctId] || data['distinctId'],
        session_id: data[:session_id] || data['session_id'] || data[:sessionId] || data['sessionId'],
        properties: properties
      }
    end

    def to_h
      {
        distinct_id: distinct_id,
        session_id: session_id,
        properties: properties.dup
      }
    end

    def apply_session_property!
      return if session_id.nil? || properties.key?('$session_id') || properties.key?(:'$session_id')

      properties['$session_id'] = session_id
    end
  end

  class << self
    def with_context(data = nil, fresh: false, **kwargs, &block)
      Context.with_context(data, fresh: fresh, **kwargs, &block)
    end

    def enter_context(data = nil, fresh: false, **kwargs)
      Context.enter_context(data, fresh: fresh, **kwargs)
    end

    def get_context
      Context.get_context
    end

    def identify_context(distinct_id)
      Context.identify_context(distinct_id)
    end

    def set_context_session(session_id)
      Context.set_context_session(session_id)
    end

    def tag_context(key_or_properties, value = nil)
      Context.tag_context(key_or_properties, value)
    end
  end
end
