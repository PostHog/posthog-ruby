# frozen_string_literal: true

require 'json'
require 'active_support/lazy_load_hooks'
require 'active_support/notifications'
require 'posthog/rails/parameter_filter'
require 'posthog/internal/context'

module PostHog
  module Rails
    module Logs
      # Optional completion records, sharing the ordinary logger's sink and controls.
      # @api private
      module Notifications
        extend ParameterFilter

        class UnsafeParameters < StandardError; end
        private_constant :UnsafeParameters

        EVENTS = {
          action_controller: %w[process_action.action_controller],
          active_record: %w[sql.active_record],
          active_job: %w[enqueue.active_job enqueue_at.active_job perform.active_job
                         enqueue_retry.active_job retry_stopped.active_job discard.active_job],
          action_mailer: %w[process.action_mailer deliver.action_mailer]
        }.freeze
        SQL_OPERATION = /\A\s*(
          SELECT|INSERT|UPDATE|DELETE|BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|WITH|CREATE|ALTER|DROP|PRAGMA|EXPLAIN
        )\b/ix
        BODIES = {
          action_controller: 'Rails controller request completed',
          active_record: 'Rails SQL query completed',
          active_job: 'Rails job lifecycle event',
          action_mailer: 'Rails mailer lifecycle event'
        }.freeze

        class << self
          def install(appender)
            @appender = appender
            selections = PostHog::Rails.config.logs_notifications
            @components = selections.is_a?(Array) ? selections & EVENTS.keys : []
            if !selections.is_a?(Array) || (selections - EVENTS.keys).any?
              PostHog::Logging.logger.warn('Invalid logs_notifications selection; ignoring unknown components')
            end
            @hooked ||= {}
            @loaded ||= {}
            @subscriptions ||= {}
            @components.each do |component|
              unless @hooked[component]
                @hooked[component] = true
                ActiveSupport.on_load(component) { Notifications.component_loaded(component) }
              end
              subscribe(component) if @loaded[component]
            end
          end

          def component_loaded(component)
            @loaded[component] = true
            subscribe(component) if @appender && @components.include?(component)
          end

          def reset
            (@subscriptions || {}).each_value do |subscriptions|
              subscriptions.each { |subscription| ActiveSupport::Notifications.unsubscribe(subscription) }
            end
            @subscriptions = {}
            @components = []
            @appender = nil
          end

          private

          def subscribe(component)
            return if @subscriptions.key?(component)

            @subscriptions[component] = EVENTS.fetch(component).map do |name|
              ActiveSupport::Notifications.subscribe(name) do |*args|
                capture(component, ActiveSupport::Notifications::Event.new(*args))
              end
            end
          end

          def capture(component, event)
            return unless @appender && PostHog::Rails.config.logs_enabled
            return unless PostHog.initialized? && PostHog.client.enabled?
            return if Thread.current[Appender::REENTRANCY_KEY]

            payload = event.payload
            error = payload[:exception_object] || payload[:error]
            if component == :active_job && %w[enqueue.active_job enqueue_at.active_job].include?(event.name) &&
               payload[:job].respond_to?(:enqueue_error)
              error ||= payload[:job].enqueue_error
            end
            error_type = error ? error.class.name : Array(payload[:exception]).first
            severity = severity_for(component, payload, error_type)
            return unless @appender.accepts_severity?(severity)

            attributes = build_attributes(component, event)
            attributes['error.type'] = error_type if error_type.is_a?(String)
            emit_in_context(component, payload) do
              @appender.add(severity, BODIES.fetch(component), attributes: attributes)
            end
          rescue StandardError => e
            return if @warned

            @warned = true
            PostHog::Logging.logger.warn("PostHog notification log failed (#{e.class}); dropping the record")
          end

          # Parameter filters are application callbacks and can themselves log or query.
          def build_attributes(component, event)
            Thread.current[Appender::REENTRANCY_KEY] = true
            { 'event.name' => event.name }.merge(attributes_for(component, event.payload))
          ensure
            Thread.current[Appender::REENTRANCY_KEY] = nil
          end

          def emit_in_context(component, payload, &block)
            job = payload[:job]
            if component == :active_job && PostHog::Rails.config.auto_instrument_active_job &&
               job.respond_to?(:posthog_logs_context, true)
              Internal::Context.with_context(
                job.send(:posthog_logs_context), fresh: true, owner: PostHog.client, enrich_current_span: false, &block
              )
            else
              yield
            end
          end

          def attributes_for(component, payload)
            case component
            when :action_controller
              attributes = pick(payload, controller: 'rails.controller', action: 'rails.action',
                                         method: 'http.request.method', status: 'http.response.status_code')
              if payload[:params].is_a?(Hash)
                attributes['rails.params'] =
                  bounded_json(controller_params(payload[:params]))
              end
              attributes
            when :active_record
              attributes = pick(payload, name: 'rails.sql.name', cached: 'rails.sql.cached')
              # Never export statements: even SQL without binds may contain literal secrets.
              operation = payload[:sql].to_s[SQL_OPERATION, 1]
              attributes['db.operation.name'] = operation.upcase if operation
              attributes
            when :active_job
              job_attributes(payload)
            when :action_mailer
              pick(payload, mailer: 'rails.mailer', action: 'rails.action')
            end
          end

          def job_attributes(payload)
            job = payload[:job]
            return {} unless job

            attributes = pick(
              { job_class: job.class.name, id: job.job_id, queue: job.queue_name,
                executions: job.executions, priority: job.priority, wait: payload[:wait] },
              job_class: 'rails.job.class', id: 'rails.job.id', queue: 'rails.job.queue',
              executions: 'rails.job.executions', priority: 'rails.job.priority', wait: 'rails.job.retry_wait'
            )
            return attributes if job.class.respond_to?(:log_arguments?) && !job.class.log_arguments?
            return attributes if defined?(::ActionMailer::MailDeliveryJob) && job.is_a?(::ActionMailer::MailDeliveryJob)

            # Unkeyed arguments have no filterable name. Do not guess which are safe.
            budget = [1000, 10_000]
            arguments = job.arguments
            arguments = if arguments.size > 100
                          '[FILTERED]'
                        else
                          arguments.map do |argument|
                            argument.is_a?(Hash) ? filtered_params(argument, budget) : '[FILTERED]'
                          end
                        end
            attributes['rails.job.arguments'] = bounded_json(arguments)
            attributes
          end

          def pick(payload, mapping)
            mapping.each_with_object({}) do |(key, name), attributes|
              value = payload[key]
              attributes[name] = safe_value(value) unless value.nil?
            end
          end

          # Rails controller notifications already contain request.filtered_parameters.
          def controller_params(params)
            copy_filter_value(params, 0, [1000, 10_000])
          rescue UnsafeParameters
            '[FILTERED]'
          end

          def filtered_params(params, budget = [1000, 10_000])
            return {} unless ::Rails.application

            if ::Rails.version.to_f >= 6.0
              require 'active_support/parameter_filter'
            else
              require 'action_dispatch/http/parameter_filter'
            end
            # Rails Proc filters can depend on key/value types and the complete original root.
            # Never pass a normalized or partially truncated parameter tree to those callbacks.
            filtered = filter_sensitive_params(copy_filter_value(params, 0, budget))
            copy_filter_value(filtered, 0, [1000, 10_000])
          rescue UnsafeParameters
            '[FILTERED]'
          end

          def copy_filter_value(value, depth, budget, copies = {}.compare_by_identity)
            raise UnsafeParameters if depth > 10 || budget[0] <= 0

            budget[0] -= 1
            case value
            when String, Symbol
              budget[1] -= value.bytesize if value.is_a?(String)
              budget[1] -= value.to_s.bytesize if value.is_a?(Symbol)
              raise UnsafeParameters if budget[1].negative?

              copies[value] ||= value.clone
            when Integer, Float, true, false, nil
              value
            when Array, Hash
              raise UnsafeParameters if value.size > 100

              copy = value.clone(freeze: false).clear
              if value.is_a?(Hash)
                raise UnsafeParameters if value.default_proc

                copy.default = copy_filter_value(value.default, depth + 1, budget, copies) unless value.default.nil?
                value.each do |key, item|
                  raise UnsafeParameters unless key.is_a?(String) || key.is_a?(Symbol)

                  copied_key = copy_filter_value(key, depth + 1, budget, copies)
                  copy[copied_key] = copy_filter_value(item, depth + 1, budget, copies)
                end
              else
                value.each { |item| copy << copy_filter_value(item, depth + 1, budget, copies) }
              end
              copy.freeze if value.frozen?
              copies[value] ||= copy
            else
              raise UnsafeParameters
            end
          end

          def bounded_json(value)
            json = JSON.generate(value)
            json.bytesize <= 10_000 ? json : JSON.generate('[FILTERED: payload too large]')
          end

          # Bound traversal and omit arbitrary object inspection from notification payloads.
          def safe_value(value, depth = 0, budget = [1000])
            return '[FILTERED]' if depth > 10 || budget[0] <= 0

            budget[0] -= 1

            case value
            when String then value[0, 10_000].dup
            when Symbol then value.to_s
            when Integer, Float, true, false, nil then value
            when Array then value.first(100).map { |item| safe_value(item, depth + 1, budget) }
            when Hash
              value.first(100).each_with_object({}) do |(key, item), result|
                next unless key.is_a?(String) || key.is_a?(Symbol)

                result[key.to_s] = safe_value(item, depth + 1, budget)
              end
            else '[FILTERED]'
            end
          end

          def severity_for(component, payload, error_type)
            return ::Logger::ERROR if error_type
            return ::Logger::DEBUG if component == :active_record

            status = payload[:status]
            return ::Logger::ERROR if status.is_a?(Integer) && status >= 500
            return ::Logger::WARN if status.is_a?(Integer) && status >= 400

            ::Logger::INFO
          end
        end
      end
    end
  end
end
