---
"posthog-ruby": minor
---

`client.emails.send` with `template_key:` takes `cc:`, `bcc:` and `attachments:`. `cc` and `bcc` take one address or a list. Each attachment is a Hash with `filename`, `content`, and an optional `content_type` and `content_id` (`content_id` shows the file inline). Pass the file's bytes as `content`, such as `File.binread('invoice.pdf')` or a list of byte values, and the client encodes them as Base64; any other String is taken as the file already encoded as Base64. A file the client can't send, such as one given by `path`, raises `PostHog::EmailError` with code `invalid_attachment` before any request.
