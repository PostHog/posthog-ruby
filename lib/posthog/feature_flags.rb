require 'concurrent'
require 'net/http'
require 'json'
require 'posthog/version'
require 'posthog/logging'
require 'digest'
class PostHog
  class FeatureFlagsPoller
    include PostHog::Logging

    def initialize(polling_interval, personal_api_key, project_api_key, host)
      @polling_interval = polling_interval || 60 * 5
      @personal_api_key = personal_api_key
      @project_api_key = project_api_key
      @host = host || 'app.posthog.com'
      @feature_flags = Concurrent::Array.new
      @loaded_flags_successfully_once = Concurrent::AtomicBoolean.new

      @task =
        Concurrent::TimerTask.new(
          execution_interval: polling_interval,
          timeout_interval: 15
        ) { _load_feature_flags }

      # load once before timer
      load_feature_flags
      @task.execute
    end

    def is_feature_enabled(key, distinct_id, default_result = false)
      # make sure they're loaded on first run
      load_feature_flags

      return default_result unless @loaded_flags_successfully_once

      feature_flag = nil


      @feature_flags.each do |flag|
        if key == flag['key']
          feature_flag = flag
          break
        end
      end

      return default_result if !feature_flag

      flag_rollout_pctg =
        if feature_flag['rollout_percentage']
          feature_flag['rollout_percentage']
        else
          100
        end
      if feature_flag['is_simple_flag']
        return is_simple_flag_enabled(key, distinct_id, flag_rollout_pctg)
      else
        data = { 'distinct_id' => distinct_id }
        res = _request('POST', 'decide', false, data)
        return res['featureFlags'].include? key
      end

      return false
    end

    def is_simple_flag_enabled(key, distinct_id, rollout_percentage)
      hash = Digest::SHA1.hexdigest "#{key}.#{distinct_id}"
      return(
        (Integer(hash[0..14], 16).to_f / 0xfffffffffffffff) <=
          (rollout_percentage / 100)
      )
    end

    def load_feature_flags(force_reload = false)
      if @loaded_flags_successfully_once.false? || force_reload
        _load_feature_flags
      end
    end

    def shutdown_poller()
      @task.shutdown
    end

    private

    def _load_feature_flags()
      res = _request('GET', 'api/feature_flag', true)
      @feature_flags.clear
      @feature_flags = res['results'].filter { |flag| flag['active'] }
      if @loaded_flags_successfully_once.false?
        @loaded_flags_successfully_once.make_true
      end
    end

    def _request(method, endpoint, use_personal_api_key = false, data = {})
      uri = URI("https://#{@host}/#{endpoint}/?token=#{@project_api_key}")
      req = nil
      if use_personal_api_key
        req = Net::HTTP::Get.new(uri)
        req['Authorization'] = "Bearer #{@personal_api_key}"
      else
        req = Net::HTTP::Post.new(uri)
        req['Content-Type'] = 'application/json'
        data['token'] = @project_api_key
        req.body = data.to_json
      end

      req['User-Agent'] = "posthog-ruby#{PostHog::VERSION}"

      begin
        res_body = nil
        res =
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            res = http.request(req)
            res_body = JSON.parse(res.body)
            return res_body
          end
      rescue Timeout::Error,
             Errno::EINVAL,
             Errno::ECONNRESET,
             EOFError,
             Net::HTTPBadResponse,
             Net::HTTPHeaderSyntaxError,
             Net::ProtocolError => e
        logger.debug("Unable to complete request to #{uri}")
        throw e
      end
    end
  end
end
