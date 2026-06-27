# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'socket'
require 'time'

require 'posthog'

module SDKComplianceAdapter
  class State
    def initialize
      @mutex = Mutex.new
      @client = nil
      reset_counters
    end

    def reset
      client = @mutex.synchronize do
        current = @client
        @client = nil
        current
      end

      begin
        client&.shutdown
      rescue StandardError => e
        record_error(e.message)
      end

      @mutex.synchronize { reset_counters }
    end

    def client
      @mutex.synchronize { @client }
    end

    def client=(new_client)
      @mutex.synchronize { @client = new_client }
    end

    def increment_captured
      @mutex.synchronize do
        @total_events_captured += 1
        @pending_events += 1
      end
    end

    def record_request(status_code, batch)
      events = batch_events(batch)
      batch_id = batch_id_for(events)
      uuids = events.filter_map { |event| event['uuid'] || event[:uuid] }

      @mutex.synchronize do
        retry_attempt = @retry_attempts[batch_id] || 0
        @requests_made << {
          timestamp_ms: (Time.now.to_f * 1000).to_i,
          status_code: status_code,
          retry_attempt: retry_attempt,
          event_count: events.length,
          uuid_list: uuids
        }

        @total_retries += 1 if retry_attempt.positive?

        if status_code == 200
          @total_events_sent += events.length
          @pending_events = [@pending_events - events.length, 0].max
          @retry_attempts.delete(batch_id)
        else
          @retry_attempts[batch_id] = retry_attempt + 1
        end
      end
    end

    def record_error(error)
      @mutex.synchronize { @last_error = error }
    end

    def snapshot
      @mutex.synchronize do
        {
          pending_events: @pending_events,
          total_events_captured: @total_events_captured,
          total_events_sent: @total_events_sent,
          total_retries: @total_retries,
          last_error: @last_error,
          requests_made: @requests_made.map(&:dup)
        }
      end
    end

    private

    def reset_counters
      @pending_events = 0
      @total_events_captured = 0
      @total_events_sent = 0
      @total_retries = 0
      @last_error = nil
      @requests_made = []
      @retry_attempts = {}
    end

    def batch_events(batch)
      JSON.parse(JSON.generate(batch))
    rescue StandardError
      []
    end

    def batch_id_for(events)
      uuids = events.filter_map { |event| event['uuid'] || event[:uuid] }.sort
      return SecureRandom.uuid if uuids.empty?

      uuids.first(3).join('-')
    end
  end

  STATE = State.new

  def self.state
    STATE
  end
end

module PostHog
  class Transport
    unless method_defined?(
      :sdk_compliance_original_send_request
    )
      alias sdk_compliance_original_send_request send_request
    end

    def send_request(api_key, batch)
      status_code, body = sdk_compliance_original_send_request(api_key, batch)
      SDKComplianceAdapter.state.record_request(status_code, batch)
      [status_code, body]
    rescue StandardError => e
      SDKComplianceAdapter.state.record_request(0, batch)
      SDKComplianceAdapter.state.record_error(e.message)
      raise
    end
  end
end

class ComplianceServer
  def initialize(host: '0.0.0.0', port: 8080)
    @server = TCPServer.new(host, port)
  end

  def run
    loop do
      socket = @server.accept
      Thread.new(socket) { |client| handle_connection(client) }
    end
  end

  private

  def handle_connection(socket)
    request_line = socket.gets
    return if request_line.nil? || request_line.strip.empty?

    method, path, = request_line.split
    headers = read_headers(socket)
    body = read_body(socket, headers)

    status, payload = route(method, path, body)
    write_response(socket, status, payload)
  rescue StandardError => e
    write_response(socket, 500, { error: e.message })
  ensure
    begin
      socket.close
    rescue StandardError
      nil
    end
  end

  def read_headers(socket)
    headers = {}
    while (line = socket.gets)
      line = line.chomp
      break if line.empty?

      key, value = line.split(':', 2)
      headers[key.downcase] = value.strip if key && value
    end
    headers
  end

  def read_body(socket, headers)
    length = headers.fetch('content-length', '0').to_i
    return '' if length.zero?

    socket.read(length)
  end

  def route(method, path, body)
    case [method, path]
    when ['GET', '/health']
      health
    when ['POST', '/init']
      init(parse_json(body))
    when ['POST', '/capture']
      capture(parse_json(body))
    when ['POST', '/flush']
      flush
    when ['POST', '/get_feature_flag']
      get_feature_flag(parse_json(body))
    when ['GET', '/state']
      [200, SDKComplianceAdapter.state.snapshot]
    when ['POST', '/reset']
      SDKComplianceAdapter.state.reset
      [200, { success: true }]
    else
      [404, { error: 'not found' }]
    end
  rescue JSON::ParserError => e
    [400, { error: "invalid JSON: #{e.message}" }]
  rescue ArgumentError => e
    SDKComplianceAdapter.state.record_error(e.message)
    [400, { error: e.message }]
  rescue StandardError => e
    SDKComplianceAdapter.state.record_error(e.message)
    [500, { error: e.message }]
  end

  def parse_json(body)
    return {} if body.nil? || body.empty?

    JSON.parse(body)
  end

  def health
    [
      200,
      {
        sdk_name: 'posthog-ruby',
        sdk_version: PostHog::VERSION,
        adapter_version: '1.0.0',
        capabilities: %w[capture_v0 encoding_gzip]
      }
    ]
  end

  def init(data)
    SDKComplianceAdapter.state.reset

    api_key = data['api_key']
    host = data['host']
    return [400, { error: 'api_key is required' }] if api_key.nil? || api_key.empty?
    return [400, { error: 'host is required' }] if host.nil? || host.empty?

    options = {
      api_key: api_key,
      host: host,
      batch_size: data.fetch('flush_at', 100),
      flush_interval_seconds: data.fetch('flush_interval_ms', 500).to_f / 1000.0,
      on_error: proc { |_status, error| SDKComplianceAdapter.state.record_error(error) },
      disable_singleton_warning: true
    }
    options[:max_retries] = data['max_retries'] if data.key?('max_retries')
    options[:enable_compression] = true if data['enable_compression'] == true

    SDKComplianceAdapter.state.client = PostHog::Client.new(options)
    [200, { success: true }]
  end

  def capture(data)
    client = SDKComplianceAdapter.state.client
    return [400, { error: 'SDK not initialized' }] unless client

    distinct_id = data['distinct_id']
    event = data['event']
    return [400, { error: 'distinct_id is required' }] if distinct_id.nil? || distinct_id.empty?
    return [400, { error: 'event is required' }] if event.nil? || event.empty?

    uuid = SecureRandom.uuid
    attrs = {
      distinct_id: distinct_id,
      event: event,
      properties: data['properties'] || {},
      uuid: uuid
    }
    attrs[:timestamp] = Time.iso8601(data['timestamp']) if data['timestamp']

    if client.capture(attrs)
      SDKComplianceAdapter.state.increment_captured
      [200, { success: true, uuid: uuid }]
    else
      [500, { error: 'capture was not queued' }]
    end
  end

  def flush
    client = SDKComplianceAdapter.state.client
    return [400, { error: 'SDK not initialized' }] unless client

    client.flush
    [200, { success: true, events_flushed: SDKComplianceAdapter.state.snapshot[:total_events_sent] }]
  rescue StandardError => e
    SDKComplianceAdapter.state.record_error(e.message)
    [500, { error: e.message, errors: [e.message] }]
  end

  def get_feature_flag(data)
    client = SDKComplianceAdapter.state.client
    return [400, { error: 'SDK not initialized' }] unless client

    key = data['key']
    distinct_id = data['distinct_id']
    return [400, { error: 'key is required' }] if key.nil? || key.empty?
    return [400, { error: 'distinct_id is required' }] if distinct_id.nil? || distinct_id.empty?

    disable_geoip = data.key?('disable_geoip') ? data['disable_geoip'] : false
    flags = client.evaluate_flags(
      distinct_id,
      groups: data['groups'] || {},
      person_properties: data['person_properties'] || {},
      group_properties: data['group_properties'] || {},
      only_evaluate_locally: data.fetch('force_remote', true) == false,
      disable_geoip: disable_geoip,
      flag_keys: [key]
    )
    value = flags.get_flag(key)
    client.flush

    [200, { success: true, value: value }]
  rescue StandardError => e
    SDKComplianceAdapter.state.record_error(e.message)
    [500, { error: e.message }]
  end

  def write_response(socket, status, payload)
    body = JSON.generate(payload)
    reason = {
      200 => 'OK', 400 => 'Bad Request', 404 => 'Not Found', 500 => 'Internal Server Error'
    }.fetch(status, 'OK')

    socket.write "HTTP/1.1 #{status} #{reason}\r\n"
    socket.write "Content-Type: application/json\r\n"
    socket.write "Content-Length: #{body.bytesize}\r\n"
    socket.write "Connection: close\r\n"
    socket.write "\r\n"
    socket.write body
  end
end

trap('TERM') { exit }
trap('INT') { exit }

ComplianceServer.new.run
