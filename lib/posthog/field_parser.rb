class PostHog
  class FieldParser
    class << self
      include PostHog::Utils

      # In addition to the common fields, capture accepts:
      #
      # - "event"
      # - "properties"
      def parse_for_capture(fields)
        common = parse_common_fields(fields)

        event = fields[:event]
        properties = fields[:properties] || {}

        check_presence!(event, 'event')
        check_is_hash!(properties, 'properties')

        isoify_dates! properties

        common.merge({
          :type => 'capture',
          :event => event.to_s,
          :properties => properties
        })
      end

      # In addition to the common fields, identify accepts:
      #
      # - "properties"
      def parse_for_identify(fields)
        common = parse_common_fields(fields)

        properties = fields[:properties] || {}
        check_is_hash!(properties, 'properties')

        isoify_dates! properties

        common.merge({
          :type => 'identify',
          :event => '$identify',
          :'$set' => properties
        })
      end

      # In addition to the common fields, alias accepts:
      #
      # - "alias"
      def parse_for_alias(fields)
        common = parse_common_fields(fields)

        distinct_id = common[:distinct_id] # must move to properties...

        alias_field = fields[:alias]
        check_presence! alias_field, 'alias'

        common.merge({
          :type => 'alias',
          :event => '$create_alias',
          :distinct_id => nil,
          :properties => {
            :distinct_id => distinct_id,
            :alias => alias_field,
          }
        })
      end

      private

      # Common fields are:
      #
      # - "timestamp"
      # - "distinct_id"
      # - "message_id"
      def parse_common_fields(fields)
        timestamp = fields[:timestamp] || Time.new
        distinct_id = fields[:distinct_id]
        message_id = fields[:message_id].to_s if fields[:message_id]

        check_timestamp! timestamp
        check_presence! distinct_id, 'distinct_id'

        parsed = {
          :timestamp => datetime_in_iso8601(timestamp),
          :library => 'posthog-ruby',
          :library_version => PostHog::VERSION.to_s,
          :messageId => message_id,
          :distinct_id => distinct_id
        }
        parsed
      end

      def check_timestamp!(timestamp)
        raise ArgumentError, 'Timestamp must be a Time' unless timestamp.is_a? Time
      end

      # private: Ensures that a string is non-empty
      #
      # obj    - String|Number that must be non-blank
      # name   - Name of the validated value
      def check_presence!(obj, name)
        if obj.nil? || (obj.is_a?(String) && obj.empty?)
          raise ArgumentError, "#{name} must be given"
        end
      end

      def check_is_hash!(obj, name)
        raise ArgumentError, "#{name} must be a Hash" unless obj.is_a? Hash
      end
    end
  end
end
