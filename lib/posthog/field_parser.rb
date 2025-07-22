# frozen_string_literal: true

require 'posthog/logging'

module PostHog
  class FieldParser
    class << self
      include PostHog::Utils
      include PostHog::Logging

      # In addition to the common fields, capture accepts:
      #
      # - "event"
      # - "properties"
      # - "groups"
      # - "uuid"
      def parse_for_capture(fields)
        common = parse_common_fields(fields)

        event = fields[:event]
        properties = fields[:properties] || {}
        groups = fields[:groups]
        uuid = fields[:uuid]
        check_presence!(event, 'event')
        check_is_hash!(properties, 'properties')

        if groups
          check_is_hash!(groups, 'groups')
          properties['$groups'] = groups
        end

        isoify_dates! properties

        common['uuid'] = uuid if valid_uuid_for_event_props? uuid

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
            '$set': properties,
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
              '$group_type': group_type,
              '$group_key': group_key,
              '$group_set': properties.merge(common[:properties] || {})
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

        if send_feature_flags && fields[:feature_variants]
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
      # obj    - String|Number that must be not blank
      # name   - The name of the validated value
      def check_presence!(obj, name)
        return unless obj.nil? || (obj.is_a?(String) && obj.empty?)

        raise ArgumentError, "#{name} must be given"
      end

      def check_is_hash!(obj, name)
        raise ArgumentError, "#{name} must be a Hash" unless obj.is_a? Hash
      end

      # @param [Object] uuid - the UUID to validate, user provided, so we don't know the type
      # @return [TrueClass, FalseClass] - true if the UUID is valid or absent, false otherwise
      def valid_uuid_for_event_props?(uuid)
        return true if uuid.nil?

        unless uuid.is_a?(String)
          logger.warn 'UUID is not a string. Ignoring it.'
          return false
        end

        is_valid_uuid = uuid.match?(/^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$/i)
        logger.warn "UUID is not valid: #{uuid}. Ignoring it." unless is_valid_uuid

        is_valid_uuid
      end
    end
  end
end
