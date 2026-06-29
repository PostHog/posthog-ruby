# frozen_string_literal: true

require 'posthog/defaults'
require 'posthog/utils'
require 'posthog/response'
require 'posthog/logging'
require 'posthog/backoff_policy'
require 'net/http'
require 'net/https'
require 'json'
require 'stringio'
require 'time'
require 'zlib'

module PostHog
  # HTTP transport used by the SDK workers.
  #
  # @api private
  class Transport
    include PostHog::Defaults::Request
    include PostHog::Utils
    include PostHog::Logging

    # @param options [Hash] Transport configuration.
    # @option options [String] :api_host Full PostHog API host URL.
    # @option options [String] :host Hostname to connect to.
    # @option options [Integer] :port Port to connect to.
    # @option options [Boolean] :ssl Whether to use HTTPS.
    # @option options [Hash] :headers HTTP headers for batch requests.
    # @option options [String] :path HTTP path for batch requests.
    # @option options [Integer] :retries Number of retry attempts for retryable failures.
    # @option options [PostHog::BackoffPolicy] :backoff_policy Backoff policy used between retries.
    # @option options [Boolean] :skip_ssl_verification Disable SSL certificate verification.
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

      @headers = (options[:headers] || HEADERS).dup
      @path = options[:path] || PATH
      @retries = options[:retries] || RETRIES
      @backoff_policy = options[:backoff_policy] || PostHog::BackoffPolicy.new
      @gzip = options[:gzip] == true
      @last_retry_after = nil

      http = Net::HTTP.new(options[:host], options[:port])
      http.use_ssl = options[:ssl]
      http.read_timeout = 8
      http.open_timeout = 4
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if options[:skip_ssl_verification]

      @http = http
      @http_mutex = Mutex.new
    end

    # Sends a batch of messages to the API
    #
    # @param api_key [String] Project API key.
    # @param batch [PostHog::MessageBatch, Array<Hash>] Batch of messages to send.
    # @return [Response] API response
    def send(api_key, batch)
      logger.debug("Sending request for #{batch.length} items")

      last_response, exception =
        retry_with_backoff(@retries) do
          status_code, body = send_request(api_key, batch)
          error =
            begin
              JSON.parse(body)['error']
            rescue JSON::ParserError
              body
            end
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

    # Closes a persistent connection if it exists.
    #
    # @return [void]
    def shutdown
      @http_mutex.synchronize do
        @http.finish if @http.started?
      end
    end

    private

    def should_retry_request?(status_code, body)
      if status_code >= 500 || [408, 429].include?(status_code)
        true # Server error, request timeout, or rate limited
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
        sleep(retry_delay_seconds)
        retry_with_backoff(retries_remaining - 1, &block)
      else
        [result, caught_exception]
      end
    end

    def retry_delay_seconds
      retry_after = parse_retry_after(@last_retry_after)
      @last_retry_after = nil
      return retry_after if retry_after

      @backoff_policy.next_interval.to_f / 1000
    end

    def parse_retry_after(value)
      return nil if value.nil? || value.empty?

      seconds = Float(value, exception: false)
      return seconds if seconds && seconds >= 0

      parsed_time = Time.httpdate(value)
      delay = parsed_time - Time.now
      delay.positive? ? delay : nil
    rescue ArgumentError
      nil
    end

    def gzip(payload)
      io = StringIO.new
      Zlib::GzipWriter.wrap(io) { |gzip| gzip.write(payload) }
      io.string
    end

    # Sends a request for the batch, returns [status_code, body]
    def send_request(api_key, batch)
      @last_retry_after = nil
      payload = JSON.generate(api_key: api_key, batch: batch)

      request = Net::HTTP::Post.new(@path, @headers)
      if @gzip
        payload = gzip(payload)
        request['Content-Encoding'] = 'gzip'
      end

      if self.class.stub
        logger.debug "stubbed request to #{@path}: " \
                     "api key = #{api_key}, batch = #{JSON.generate(batch)}"

        [200, '{}']
      else
        @http_mutex.synchronize do
          @http.start unless @http.started? # Maintain a persistent connection
          response = @http.request(request, payload)
          @last_retry_after = response['Retry-After']
          [response.code.to_i, response.body]
        end
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
