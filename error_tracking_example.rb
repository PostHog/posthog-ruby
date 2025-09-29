#!/usr/bin/env ruby
# frozen_string_literal: true

# Error Tracking Example for PostHog Ruby Client
#
# This example demonstrates how to use the PostHog Ruby client for both 
# automatic and manual error tracking.
# Make sure to install the gem first:
#   gem install posthog

require 'posthog'

# AUTOMATIC ERROR TRACKING SETUP
# This is the recommended approach for most applications
puts "=== AUTOMATIC ERROR TRACKING SETUP ==="

PostHog.configure do |config|
  config.api_key = 'your_api_key_here'  # Replace with your actual API key  
  config.host = 'https://us.i.posthog.com'  # Use your PostHog instance URL
  config.auto_capture_exceptions = true  # Enable automatic capture
  config.test_mode = true  # For this example
  
  # Optional: Customize ignored exceptions
  config.ignored_exceptions = [
    'ActionController::RoutingError',
    /test_error/  # Ignore our test errors
  ]
end

puts "PostHog configured for automatic error tracking!"

# Example: Automatic capture in action
puts "\n=== AUTOMATIC CAPTURE EXAMPLES ==="

# Any uncaught exception will now be automatically sent to PostHog
begin
  raise StandardError, "This error will be automatically captured!"
rescue StandardError => e
  puts "Caught: #{e.message}"
  # The exception was automatically captured before we caught it
end

# MANUAL ERROR TRACKING EXAMPLES  
# Use these for handled exceptions or custom reporting
puts "\n=== MANUAL ERROR TRACKING EXAMPLES ==="

# Initialize client for manual examples (automatic config is also available as PostHog.capture_exception)
posthog = PostHog::Client.new(
  api_key: 'your_api_key_here',  # Replace with your actual API key
  host: 'https://us.i.posthog.com',  # Use your PostHog instance URL
  test_mode: true
)

# Example 1: Basic exception tracking
begin
  # Some code that might fail
  result = 10 / 0
rescue StandardError => e
  posthog.capture_exception(e, distinct_id: 'user_123')
end

# Example 2: Exception tracking with additional context
begin
  # Simulate a payment processing error
  raise StandardError, "Payment failed for insufficient funds"
rescue StandardError => e
  posthog.capture_exception(e, {
    distinct_id: 'user_456',
    tags: { 
      component: 'payment_processor',
      severity: 'high',
      payment_method: 'credit_card'
    },
    extra: {
      amount: 99.99,
      currency: 'USD',
      merchant_id: 'merchant_789',
      transaction_id: 'txn_abcd1234'
    }
  })
end

# Example 3: Using hash format for more control
custom_exception = {
  distinct_id: 'user_789',
  exception: ArgumentError.new("Invalid user input"),
  exception_fingerprint: 'custom_error_group_001',  # Custom grouping
  handled: false,  # Mark as unhandled
  mechanism_type: 'middleware',  # Custom mechanism
  tags: {
    environment: 'production',
    version: '1.2.3'
  },
  extra: {
    user_agent: 'Mozilla/5.0...',
    url: '/api/users/create',
    request_id: 'req_xyz789'
  }
}

posthog.capture_exception(custom_exception)

# Example 4: Rails Integration (AUTOMATIC - Recommended)
puts "\n=== RAILS AUTOMATIC INTEGRATION ==="

# In config/initializers/posthog.rb
# PostHog.configure do |config|
#   config.api_key = ENV['POSTHOG_API_KEY']
#   config.auto_capture_exceptions = true  # Automatic capture for Rails
#   
#   # All Rails exceptions are now automatically captured with context:
#   # - Controller name and action
#   # - Request parameters (filtered)
#   # - User agent, IP, URL
#   # - User identification (if available)
#   # - Environment info
# end

# Rails Controller with automatic capture and helper methods
class ApplicationController < ActionController::Base
  # No rescue_from needed! Automatic capture handles uncaught exceptions
  
  # Use helper methods for manual tracking
  def create_payment
    begin
      PaymentService.charge(params[:amount])
    rescue PaymentError => e
      # Manual capture for handled exceptions with extra context
      posthog_capture_exception(e, {
        tags: { payment_method: params[:method] },
        extra: { amount: params[:amount], currency: 'USD' }
      })
      render json: { error: 'Payment failed' }, status: 422
    end
  end
  
  # Track user actions
  def user_signed_up
    posthog_capture('user_signed_up', { plan: params[:plan] })
    posthog_identify({ name: current_user.name, email: current_user.email })
  end
end

# Example 5: Background job error tracking
class ProcessPaymentJob
  def perform(payment_id)
    payment = Payment.find(payment_id)
    PaymentProcessor.process(payment)
  rescue StandardError => e
    PostHog::Client.new.capture_exception(e, {
      distinct_id: "payment_#{payment_id}",
      tags: {
        job: self.class.name,
        queue: queue_name
      },
      extra: {
        payment_id: payment_id,
        payment_amount: payment&.amount,
        retry_count: executions - 1
      }
    })
    
    raise # Re-raise to trigger job retry
  end
end

# Example 6: Custom error classes with automatic tagging
class PaymentError < StandardError
  attr_reader :payment_method, :amount

  def initialize(message, payment_method: nil, amount: nil)
    super(message)
    @payment_method = payment_method
    @amount = amount
  end
end

begin
  raise PaymentError.new(
    "Payment declined by bank", 
    payment_method: 'visa', 
    amount: 150.00
  )
rescue PaymentError => e
  posthog.capture_exception(e, {
    distinct_id: 'user_999',
    tags: {
      payment_method: e.payment_method,
      error_type: 'payment_declined'
    },
    extra: {
      amount: e.amount
    }
  })
end

# Example 7: Exception with custom fingerprinting for better grouping
def process_user_data(user_data)
  raise ArgumentError, "Name cannot be blank" if user_data[:name].blank?
  raise ArgumentError, "Email cannot be blank" if user_data[:email].blank?
rescue ArgumentError => e
  # Group all validation errors together regardless of specific field
  posthog.capture_exception(e, {
    distinct_id: user_data[:id],
    exception_fingerprint: 'user_validation_error',  # Custom grouping
    tags: { 
      validation_type: 'user_data',
      field: e.message.include?('Name') ? 'name' : 'email'
    }
  })
end

puts "Error tracking examples completed!"
puts "Check your PostHog instance at #{posthog.instance_variable_get(:@api_key)} for the captured exceptions."

# Don't forget to flush the client to ensure all events are sent
posthog.flush