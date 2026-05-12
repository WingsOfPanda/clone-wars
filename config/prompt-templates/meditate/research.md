Investigate the following topic from multiple angles. Your job is not to
recommend; your job is to expose the landscape — approaches, tradeoffs,
SOTA evidence, and open questions.

Topic: {{TOPIC}}

Output requirements — write to {{WRITE_TO}} with this EXACT structure:

  # Findings: {{TOPIC}}

  ## Summary
  <2-3 sentence overview, free-form prose>

  ## Approaches
  1. [<citation>] <approach name> — <one-line description>
  2. [<citation>] <approach name> — <one-line description>
  ...

  ## SOTA evidence
  {{LIT_GUIDANCE}}

  ## Tradeoffs
  - <approach A> wins on <criterion> because <reason with citation>
  - <approach A> loses on <criterion> because <reason with citation>
  - <approach B> wins on <criterion> because <reason with citation>
  ...

  ## Independent Discovery
  Files / URLs / papers you opened during research that go beyond what
  Master Yoda's identity prompt suggested. Cite at least 3 sources you
  found on your own — this is an anti-correlated-blind-spots guard.

  ## Open questions
  - <question 1 that the research could not resolve>
  - <question 2>

  ## Notes
  <any free-form additions; not parsed by Master Yoda>

Citation format options:
  - <file path>:<line>          e.g. src/auth/store.py:42
  - <file path>:<line-range>    e.g. src/auth/refresh.py:15-30
  - <URL>                       e.g. https://arxiv.org/abs/2401.04088
  - paper:<id>                  e.g. paper:arxiv:2401.04088
  - runtime: <command>          e.g. runtime: pytest tests/test_x.py

Every Approach AND every Tradeoff bullet MUST have a citation in
[brackets]. Bullets without citations will be silently dropped by Yoda's
synthesis — and if NO approach has a citation, your findings will be
flagged as malformed in the report.

Research methods:
Use any tool available in your environment to investigate. When local
evidence is insufficient or the topic references external knowledge
(papers, RFCs, library docs, vendor APIs, benchmarks), you SHOULD use
WebSearch / WebFetch (or the equivalent in your TUI) to find authoritative
sources. Prefer primary sources (specifications, official docs, source
repos, peer-reviewed papers) over blog posts. If a tool is not available,
fall back to local-only investigation and note the gap as an [unverified]
claim.

Important: this is NOT a recommendation phase. Do not pick a "best"
approach. Surface the landscape; Yoda will synthesize the tradeoff matrix
and a separate adversary round will challenge the synthesis before the
final landscape doc is written.

Then emit {"event":"done", "summary":"researched {{TOPIC}}", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
