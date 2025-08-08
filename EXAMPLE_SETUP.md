# PostHog Ruby SDK Example Setup Guide

This guide helps you set up the example script to demonstrate all PostHog Ruby SDK features, including the new complex cohort evaluation capabilities.

## Quick Start

1. **Set up credentials:**
   ```bash
   cp .env.example .env
   # Edit .env with your actual PostHog credentials
   ```

2. **Run the example:**
   ```bash
   ruby example.rb
   ```

3. **Choose an example to run from the interactive menu**

## Detailed Setup

### 1. Environment Configuration

Create a `.env` file with your PostHog credentials:

```bash
# Your PostHog project API key (found on the /setup page in PostHog)
POSTHOG_API_KEY=phc_your_project_key_here

# Your personal API key (required for local feature flag evaluation) 
POSTHOG_PERSONAL_API_KEY=phx_your_personal_key_here

# PostHog host URL
POSTHOG_HOST=https://app.posthog.com  # or your self-hosted URL
```

### 2. Complex Cohort Example Setup

For the complex cohort evaluation example (option 3), you need to create a specific cohort and feature flag in your PostHog instance:

#### Step 1: Create Supporting Cohort

**Go to:** PostHog → People → Cohorts → New Cohort

- **Name:** `posthog-team` (or any name)
- **Conditions:**
  ```
  OR Group:
  ├── email contains "@posthog.com"
  └── $host equals "localhost:8010"
  ```

#### Step 2: Create Main Cohort

**Go to:** PostHog → People → Cohorts → New Cohort

- **Name:** `complex-cohort`
- **Description:** `Complex cohort for Ruby SDK demo`
- **Conditions:**
  ```
  OR Group (Top Level):
  ├── AND Group 1:
  │   ├── email contains "@example.com"
  │   └── is_email_verified = "true"
  └── OR Group 2:
      └── User belongs to cohort "posthog-team"
  ```

#### Step 3: Create Feature Flag

**Go to:** PostHog → Feature Flags → New Feature Flag

- **Name:** `test-complex-cohort-flag`
- **Key:** `test-complex-cohort-flag`
- **Release Conditions:**
  - User belongs to cohort `complex-cohort`
  - Rollout percentage: 100%

## What the Examples Demonstrate

### Option 1: Identify and Capture
- Event tracking with properties
- User identification and aliases
- Group identification
- Property setting ($set, $set_once)

### Option 2: Feature Flag Local Evaluation  
- Basic feature flag evaluation
- Location-based flags
- Local-only evaluation
- Bulk flag retrieval

### Option 3: Complex Cohort Evaluation ⭐ **NEW**
This demonstrates the Ruby SDK's new capability to evaluate complex cohorts locally:

**Test Cases:**
- ✅ `user@example.com` with `is_email_verified=true` → should match (first AND group)
- ✅ `dev@posthog.com` → should match (nested cohort reference)  
- ❌ `user@other.com` → should not match (no conditions met)

**Key Features Showcased:**
- Multi-level nested logic (OR → AND → properties)
- Cohort-within-cohort references
- Mixed property operators (`icontains`, `exact`)
- Zero API calls for complex evaluation
- Ruby SDK feature parity with Python/Node.js SDKs

### Option 4: Feature Flag Payloads
- Getting payloads for specific flags
- Bulk payload retrieval
- Remote config payloads

## Troubleshooting

### Authentication Errors
- Verify your API keys are correct
- Ensure personal API key has proper permissions
- Check that your host URL is correct

### Missing Feature Flag
If `test-complex-cohort-flag` doesn't exist, the example will still run but return `false` for all tests. Follow the setup steps above to create the required cohort and flag.

### Local Evaluation Not Working
- Ensure you have a personal API key (not just project API key)
- Check that feature flags are active in your PostHog instance
- Verify cohort conditions are properly configured

## Example Output

When working correctly, option 3 should output:
```
✅ Verified @example.com user: true
✅ @posthog.com user: true  
❌ Regular user: false

🎯 Results Summary:
   - Complex nested cohorts evaluated locally: ✅ YES
   - Zero API calls needed: ✅ YES (all evaluated locally)
   - Ruby SDK now has cohort parity: ✅ YES
```

This demonstrates that the Ruby SDK can now evaluate complex, nested cohorts entirely locally - a major new capability that brings it to feature parity with other PostHog server-side SDKs!