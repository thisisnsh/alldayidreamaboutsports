# Security policy

Security fixes target the current main branch and the latest released app.

Please report suspected vulnerabilities privately to **hello@thisisnsh.com**
with the subject “All Day I Dream About Sports security report”. Include the
version/commit, affected component, reproduction steps, and expected impact.
Do not publish credentials or personal data in issues or pull requests.

Prefer local reproductions with fake data. Do not load-test production, mutate
live scores, or access other users’ or services’ data. The maintainer will
coordinate disclosure and remediation with the reporter; there is no promised
response-time SLA or bug bounty.

The backend accepts only configured Google service identities. Public app data
is served through the scores CDN. Never commit cloud credentials, signing keys,
Firebase configuration files, or local environment files. CI checks dependency
advisories and committed secrets; these checks do not replace code review.
