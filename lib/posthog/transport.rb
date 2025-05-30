# frozen_string_literal: true

require 'posthog/defaults'
require 'posthog/utils'
require 'posthog/response'
require 'posthog/logging'
require 'posthog/backoff_policy'
require 'net/http'
require 'net/https'
require 'json'

module PostHog
  class Transport
    include PostHog::Defaults::Request
    include PostHog::Utils
    include PostHog::Logging

    def initialize(options = {})
      if options[:api_host]
        uri = URI.parse(options[:api_host])
        options[:host] = uri.host
        options[:ssl] = uri.scheme == 'https'
        options[:port] = uri.port
      end

      options[:host] = options[:host].nil? ? HOST : options[:host]
      options[:port] = options[:port].nil? ? PORT : options[:port]
      options[:ssl] = options[:ssl].nil? ? SSL : options[:ssl]

      @headers = options[:headers] || HEADERS
      @path = options[:path] || PATH
      @retries = options[:retries] || RETRIES
      @backoff_policy = options[:backoff_policy] || PostHog::BackoffPolicy.new

      http = Net::HTTP.new(options[:host], options[:port])
      http.use_ssl = options[:ssl]
      http.read_timeout = 8
      http.open_timeout = 4
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if options[:skip_ssl_verification]

      @http = http
    end

    # Sends a batch of messages to the API
    #
    # @return [Response] API response
    def send(api_key, batch)
      logger.debug("Sending request for #{batch.length} items")

      last_response, exception =
        retry_with_backoff(@retries) do
          status_code, body = send_request(api_key, batch)
          error = JSON.parse(body)['error']
          should_retry = should_retry_request?(status_code, body)
          logger.debug("Response status code: #{status_code}")
          logger.debug("Response error: #{error}") if error

          [Response.new(status_code, error), should_retry]
        end

      if exception
        logger.error(exception.message)
        exception.backtrace.each { |line| logger.error(line) }
        Response.new(-1, exception.to_s)
      else
        last_response
      end
    end

    # Closes a persistent connection if it exists
    def shutdown
      @http.finish if @http.started?
    end

    private

    def should_retry_request?(status_code, body)
      if status_code >= 500
        true # Server error
      elsif status_code == 429 # rubocop:disable Lint/DuplicateBranch
        true # Rate limited
      elsif status_code >= 400
        logger.error(body)
        false # Client error. Do not retry, but log
      else
        false
      end
    end

    # Takes a block that returns [result, should_retry].
    #
    # Retries upto `retries_remaining` times, if `should_retry` is false or
    # an exception is raised. `@backoff_policy` is used to determine the
    # duration to sleep between attempts
    #
    # Returns [last_result, raised_exception]
    def retry_with_backoff(retries_remaining, &block)
      result, caught_exception = nil
      should_retry = false

      begin
        result, should_retry = yield
        return result, nil unless should_retry
      rescue StandardError => e
        should_retry = true
        caught_exception = e
      end

      if should_retry && (retries_remaining > 1)
        logger.debug("Retrying request, #{retries_remaining} retries left")
        sleep(@backoff_policy.next_interval.to_f / 1000)
        retry_with_backoff(retries_remaining - 1, &block)
      else
        [result, caught_exception]
      end
    end

    # Sends a request for the batch, returns [status_code, body]
    def send_request(api_key, batch)
      payload = JSON.generate(api_key: api_key, batch: batch)

      request = Net::HTTP::Post.new(@path, @headers)

      if self.class.stub
        logger.debug "stubbed request to #{@path}: " \
                     "api key = #{api_key}, batch = #{JSON.generate(batch)}"

        [200, '{}']
      else
        @http.start unless @http.started? # Maintain a persistent connection
        response = @http.request(request, payload)
        [response.code.to_i, response.body]
      end
    end

    class << self
      attr_writer :stub

      def stub
        @stub || ENV.fetch('STUB', nil)
      end
    end
  end
end
