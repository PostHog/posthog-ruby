# frozen_string_literal: true

require 'posthog/rails/capture_exceptions'
require 'posthog/internal/context'
require 'posthog/rails/request_metadata'

module PostHog
  module Rails
    # @api private
    class ActionCableExceptionContext < ExceptionContext
      def initialize(request, connection)
        super(request)
        @connection = connection
      end

      private

      def extract_current_user(controller)
        return super if controller

        method_name = PostHog::Rails.config&.current_user_method || :current_user
        @connection.send(method_name) if @connection.respond_to?(method_name, true)
      rescue StandardError
        nil
      end
    end

    # @api private
    class ActionCableCapture < CaptureExceptions
      include ParameterFilter

      def initialize(connection, operation, channel: nil, data: nil)
        super(nil)
        @connection = connection
        @operation = operation
        @channel = channel
        @data = data
      end

      def call
        with_context do
          yield
        rescue StandardError => e
          dispatch = ActionCableDispatch.current(@connection) if @channel
          if dispatch
            dispatch.defer(self, e)
          else
            capture_exception(e, connection_env)
          end
          raise
        end
      end

      def with_context(&block)
        Internal::Context.with_context(context_data(connection_env), fresh: true, owner: PostHog.client,
                                                                     enrich_current_span: false, &block)
      end

      def report(exception)
        with_context { capture_exception(exception, connection_env) }
      end

      private

      def connection_env
        env = @connection.env if @connection.respond_to?(:env)
        env.is_a?(Hash) ? env : {}
      rescue StandardError
        {}
      end

      def context_data(env)
        request = ActionDispatch::Request.new(env)
        data = { properties: RequestMetadata.extract(request) }
        return data if PostHog::Rails.config&.use_tracing_headers == false

        data.merge(
          distinct_id: TracingHeaders.extract_header(request, 'X-POSTHOG-DISTINCT-ID'),
          session_id: TracingHeaders.extract_header(request, 'X-POSTHOG-SESSION-ID')
        )
      rescue StandardError
        {}
      end

      def capture_exception(exception, env)
        return unless PostHog.initialized? && PostHog.client.enabled?
        return unless should_capture?(exception)

        PostHog.capture_exception(
          exception,
          extract_distinct_id(env),
          build_cable_properties,
          mechanism: { 'type' => 'middleware', 'handled' => false }
        )
      rescue StandardError => e
        PostHog::Logging.logger.error("Failed to capture Action Cable exception: #{e.class}")
      end

      def extract_distinct_id(env)
        ActionCableExceptionContext.new(ActionDispatch::Request.new(env), @connection).distinct_id
      rescue StandardError
        nil
      end

      def filter_sensitive_params(params)
        return ParameterFilter::EMPTY_HASH unless params.is_a?(Hash)

        filters = Array(::Rails.application&.config&.filter_parameters)
        config = @connection.config if @connection.respond_to?(:config)
        filters += Array(config.filter_parameters) if config.respond_to?(:filter_parameters)
        ParameterFilter.backend.new(filters.uniq).filter(params)
      end

      def build_cable_properties
        properties = {
          '$exception_source' => 'rails.action_cable',
          '$exception_level' => 'error',
          '$action_cable_operation' => @operation,
          '$connection_class' => @connection.class.name
        }
        return properties unless @channel

        properties['$channel_class'] = @channel.class.name
        properties['$channel_params'] = safe_serialize(filter_sensitive_params(@channel.params))
        if @data
          filtered_data = safe_serialize(filter_sensitive_params(@data))
          properties['$action_data'] = filtered_data
          properties['$action'] = filtered_data['action'].presence || 'receive'
        end
        properties
      end
    end

    # A channel error reaches connection rescue handlers outside the channel boundary.
    # Keep its capture pending only for the current command, not on the shared socket.
    # @api private
    class ActionCableDispatch
      def self.current(connection)
        dispatch = Thread.current[:posthog_cable_dispatch]
        dispatch if dispatch&.connection.equal?(connection)
      end

      attr_reader :connection, :exception
      attr_accessor :handled

      def initialize(connection)
        @connection = connection
      end

      def defer(capture, exception)
        return if @capture

        @capture = capture
        @exception = exception
      end

      def call
        previous = Thread.current[:posthog_cable_dispatch]
        Thread.current[:posthog_cable_dispatch] = self
        result = yield
        @capture&.report(@exception) unless handled
        result
      rescue StandardError => e
        @capture&.report(e)
        raise
      ensure
        Thread.current[:posthog_cable_dispatch] = previous
      end
    end

    # @api private
    module ActionCableSubscriptionsExtensions
      def execute_command(data)
        ActionCableCapture.new(@connection, 'command').with_context do
          ActionCableDispatch.new(@connection).call { super }
        end
      end
    end

    # @api private
    module ActionCableContext
      private

      def with_posthog_cable_context(operation, connection: self, channel: nil, data: nil, &block)
        ActionCableCapture.new(connection, operation, channel: channel, data: data).call(&block)
      end
    end

    # @api private
    module ActionCableConnectionExtensions
      include ActionCableContext

      def rescue_with_handler(exception)
        result = super
        dispatch = ActionCableDispatch.current(self)
        dispatch.handled = true if result && dispatch&.exception.equal?(exception)
        result
      end

      private

      def handle_open
        with_posthog_cable_context('connect') { super }
      end

      def handle_close
        with_posthog_cable_context('disconnect') { super }
      end
    end

    # @api private
    module ActionCableChannelExtensions
      include ActionCableContext

      def subscribe_to_channel
        with_posthog_cable_context('subscribe', connection: connection, channel: self) { super }
      end

      def unsubscribe_from_channel
        with_posthog_cable_context('unsubscribe', connection: connection, channel: self) { super }
      end

      def perform_action(data)
        with_posthog_cable_context('action', connection: connection, channel: self, data: data) { super }
      end
    end

    private_constant :ActionCableExceptionContext, :ActionCableCapture, :ActionCableContext,
                     :ActionCableConnectionExtensions, :ActionCableChannelExtensions,
                     :ActionCableDispatch, :ActionCableSubscriptionsExtensions
  end
end
