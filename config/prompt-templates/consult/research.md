Investigate the following topic and produce structured findings.

Topic: {{TOPIC}}

Output requirements — write to {{WRITE_TO}} with this EXACT structure:

  # Findings: {{TOPIC}}

  ## Summary
  <2-3 sentence overview, free-form prose>

  ## Claims
  1. [<source citation>] <one-sentence claim>
  2. [<source citation>] <one-sentence claim>
  ...

  ## Notes
  <any free-form additions; not parsed by Master Yoda>

Citation format options:
  - <file path>:<line>          e.g. src/auth/store.py:42
  - <file path>:<line-range>    e.g. src/auth/refresh.py:15-30
  - <URL>                       e.g. https://datatracker.ietf.org/doc/html/rfc6749
  - runtime: <command>          e.g. runtime: pytest tests/test_auth.py

Each claim must have a citation in [brackets]. Claims without citations
will be silently dropped by Master Yoda — and if NO claim has a
citation, your findings will be flagged as malformed in the report.

Research methods (v0.3.2):
You may use any tool available in your environment to investigate this
topic. When local repository evidence is insufficient or the topic
references external knowledge (RFCs, standards, library docs, vendor
APIs, recent CVEs, design patterns), you SHOULD use WebSearch / WebFetch
(or the equivalent in your TUI) to find authoritative sources and cite
them as URL citations. The citation parser already handles `https://...`
strings — see the URL row in the citation-format list above. Prefer
primary sources (specifications, official docs, source repos) over blog
posts. If a tool is not available in your environment, fall back to
local-only investigation and note the gap as an [unverified] claim.

{{TARGETS_BLOCK_START}}## Per-sub-project structure

This consultation spans multiple sub-projects. Structure your `findings.md`
with one `### <sub-project>` heading per sub-project, in this order:

{{TARGETS}}

Each sub-section's claims block contributes to the per-sub-project diff +
verify pass downstream.{{TARGETS_BLOCK_END}}

Then emit {"event":"done", "summary":"researched {{TOPIC}}", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
