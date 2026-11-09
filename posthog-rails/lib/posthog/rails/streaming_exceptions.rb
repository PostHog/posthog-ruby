# frozen_string_literal: true

module PostHog
  module Rails
    # @api private
    class StreamingExceptions < CaptureExceptions
      module LiveReporter
        private

        def log_error(exception)
          StreamingExceptions.capture(exception, source: 'rails.live', controller: self)
          super
        end
      end

      module TemplateReporter
        private

        def log_error(exception)
          StreamingExceptions.capture(exception, source: 'rails.streaming_template')
          super
        end
      end

      def self.install
        return if @installed

        ActiveSupport.on_load(:action_controller_live) do
          StreamingExceptions.install_live(self)
        end
        # Rails 8.1.4 added the Live hook to avoid resolving Response too early.
        if Gem::Version.new(::Rails.version) < Gem::Version.new('8.1.4')
          ActiveSupport.on_load(:action_controller) do
            StreamingExceptions.install_live(ActionController::Live)
          end
        end
        ActiveSupport.on_load(:action_view) do
          body = ActionView::StreamingTemplateRenderer::Body
          body.prepend(TemplateReporter) unless body < TemplateReporter
        end
        @installed = true
      end

      def self.install_live(live)
        return if live < LiveReporter

        # Older Rails exposes log_error publicly. Keep visibility local to the
        # target instead of changing the shared reporter module.
        reporter = Module.new { include LiveReporter }
        visibility = %i[public protected private].find { |value| live.send("#{value}_method_defined?", :log_error) }
        reporter.send(visibility, :log_error)
        live.prepend(reporter)
      end

      def self.capture(exception, source:, controller: nil)
        return unless PostHog.initialized? && PostHog.client.enabled?

        new(nil).report(exception, source: source, controller: controller)
      rescue StandardError
        # Reporting must never replace Rails' logging result or exception.
        nil
      end

      def report(exception, source:, controller:)
        return unless should_capture?(exception)

        env = controller&.request&.env
        if env
          # Live may log after middleware has returned or in another scope.
          # Use its own request, never a retained or unrelated ambient context.
          RequestContext.new(lambda do |_env|
            capture_streaming_exception(exception, source, env)
          end, enrich_current_span: false).call(env)
        else
          capture_streaming_exception(exception, source, env)
        end
      end

      private

      def capture_streaming_exception(exception, source, env = nil)
        properties = env ? build_properties(env) : {}
        properties['$exception_source'] = source
        properties['$exception_level'] = 'error'
        PostHog.capture_exception(
          exception,
          env ? extract_distinct_id(env) : nil,
          properties,
          mechanism: { 'type' => 'middleware', 'handled' => false }
        )
      end
    end

    private_constant :StreamingExceptions
  end
end
