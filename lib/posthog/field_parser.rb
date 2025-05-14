class PostHog
  class FieldParser
    class << self
      include PostHog::Utils

      # In addition to the common fields, capture accepts:
      #
      # - "event"
      # - "properties"
      # - "groups"
      def parse_for_capture(fields)
        common = parse_common_fields(fields)

        event = fields[:event]
        properties = fields[:properties] || {}
        groups = fields[:groups]

        check_presence!(event, 'event')
        check_is_hash!(properties, 'properties')

        if groups
          check_is_hash!(groups, 'groups')
          properties['$groups'] = groups
        end

        isoify_dates! properties

        common.merge(
          {
            type: 'capture',
            event: event.to_s,
            properties: properties.merge(common[:properties] || {})
          }
        )
      end

      # In addition to the common fields, identify accepts:
      #
      # - "properties"
      def parse_for_identify(fields)
        common = parse_common_fields(fields)

        properties = fields[:properties] || {}
        check_is_hash!(properties, 'properties')

        isoify_dates! properties

        common.merge(
          {
            type: 'identify',
            event: '$identify',
            :'$set' => properties,
            properties: properties.merge(common[:properties] || {})
          }
        )
      end

      def parse_for_group_identify(fields)
        properties = fields[:properties] || {}
        group_type = fields[:group_type]
        group_key = fields[:group_key]

        check_presence!(group_type, 'group type')
        check_presence!(group_key, 'group_key')
        check_is_hash!(properties, 'properties')

        fields[:distinct_id] ||= "$#{group_type}_#{group_key}"
        common = parse_common_fields(fields)

        isoify_dates! properties

        common.merge(
          {
            event: '$groupidentify',
            properties: {
              :'$group_type' => group_type,
              :'$group_key' => group_key,
              :'$group_set' => properties.merge(common[:properties] || {})
            }
          }
        )
      end

      # In addition to the common fields, alias accepts:
      #
      # - "alias"
      def parse_for_alias(fields)
        common = parse_common_fields(fields)

        distinct_id = common[:distinct_id] # must both be set and move to properties

        alias_field = fields[:alias]
        check_presence! alias_field, 'alias'

        common.merge(
          {
            type: 'alias',
            event: '$create_alias',
            distinct_id: distinct_id,
            properties:
              { distinct_id: distinct_id, alias: alias_field }.merge(
                common[:properties] || {}
              )
          }
        )
      end

      private

      # Common fields are:
      #
      # - "timestamp"
      # - "distinct_id"
      # - "message_id"
      # - "send_feature_flags"
      def parse_common_fields(fields)
        timestamp = fields[:timestamp] || Time.new
        distinct_id = fields[:distinct_id]
        message_id = fields[:message_id].to_s if fields[:message_id]
        send_feature_flags = fields[:send_feature_flags]

        check_timestamp! timestamp
        check_presence! distinct_id, 'distinct_id'

        parsed = {
          timestamp: datetime_in_iso8601(timestamp),
          library: 'posthog-ruby',
          library_version: PostHog::VERSION.to_s,
          messageId: message_id,
          distinct_id: distinct_id,
          properties: {
            '$lib' => 'posthog-ruby',
            '$lib_version' => PostHog::VERSION.to_s
          }
        }

        if send_feature_flags
          feature_variants = fields[:feature_variants]
          active_feature_variants = {}
          feature_variants.each do |key, value|
            parsed[:properties]["$feature/#{key}"] = value
            active_feature_variants[key] = value if value != false
          end
          parsed[:properties]['$active_feature_flags'] = active_feature_variants.keys
        end
        parsed
      end

      def check_timestamp!(timestamp)
        return if timestamp.is_a? Time

        raise ArgumentError, 'Timestamp must be a Time'
      end

      # private: Ensures that a string is non-empty
      #
      # obj    - String|Number that must be non-blank
      # name   - Name of the validated value
      def check_presence!(obj, name)
        return unless obj.nil? || (obj.is_a?(String) && obj.empty?)

        raise ArgumentError, "#{name} must be given"
      end

      def check_is_hash!(obj, name)
        raise ArgumentError, "#{name} must be a Hash" unless obj.is_a? Hash
      end
    end
  end
end
