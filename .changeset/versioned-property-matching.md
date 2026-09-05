---
"posthog-ruby": patch
---

Honor the definitions response's `property_matching_version` during local flag evaluation, including groups, cohorts, dependencies, and external definition caches. Version 2 uses explicit equality with the service's empty-filter truthiness rule and JSON null/composite representations. Missing/1 now intentionally matches the service's legacy aggregate boolean truthiness instead of Ruby's previous unversioned explicit behavior (for example, `false` matches `"banana"` in legacy mode). Definition refreshes retain matching rules with their snapshot and version-only changes take effect on the next evaluation. Cache providers must preserve the version alongside definitions; older entries default to legacy.
