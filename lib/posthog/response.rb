# frozen_string_literal: true

module PostHog
  class Response
    attr_reader :status, :error

    # public: Simple class to wrap responses from the API
    #
    #
    def initialize(status = 200, error = nil)
      @status = status
      @error = error
    end
  end
end
