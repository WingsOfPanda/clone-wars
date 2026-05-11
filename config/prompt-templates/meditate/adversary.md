You are now playing adversary against a synthesized landscape doc that
was built from your earlier research findings (and the findings of your
fellow troopers). Your job is to break confidence in the synthesis — not
to validate it.

Default to skepticism. Assume the synthesis can fail in subtle, high-cost,
or hard-to-detect ways until evidence says otherwise. Do not give credit
for good intent or partial coverage.

The synthesis to challenge:

{{LANDSCAPE_DRAFT}}

Attack surface — prioritize these failure modes:
- Approaches that were missed or wrongly excluded from the landscape
- Tradeoff matrix rows where the "Best fit" assignment is wrong or
  weakly justified
- Citations that don't actually support the claim attached to them
  (open the cited file/URL and verify the claim is grounded)
- Convergent findings across troopers that may share a correlated blind
  spot (e.g., all read the same paper, all missed the same recent
  development)
- Frames the synthesis adopted that exclude valid alternative frames
  (e.g., assumed online inference when batch is also valid)
- Open questions that should have been answered but were filed instead
- SOTA claims that are stale (paper from 3+ years ago marked "current SOTA")

Output requirements — write to {{OUT_PATH}}:

  # Adversary critique: {{COMMANDER}}'s pass

  ## Verdict
  <one line: needs-attention | minor-revisions | accept>

  ## Material findings
  Each finding answers:
  1. What is the weakness in the synthesis?
  2. Why is that synthesis claim vulnerable?
  3. What concrete change to the landscape doc would reduce the risk?

  ### Finding 1: <one-line summary>
  - **Targets:** <which section/row/citation in the draft>
  - **Why vulnerable:** <evidence the claim is shaky, with new citation>
  - **Concrete fix:** <what to change in the landscape doc>

  ### Finding 2: ...

  ## Notes
  <optional free-form additions>

Calibration rules:
- Prefer one strong finding over several weak ones
- Do not dilute serious issues with stylistic nits
- If the synthesis looks defensible, say so directly and return zero
  findings (verdict: accept). Padding with weak adversarial reaches is
  worse than admitting the draft is sound.
- Be aggressive but stay grounded — every finding must be defensible
  from the cited evidence, not speculative

Then emit {"event":"done", "summary":"adversary critique done", "ts":"<iso>"} to your outbox.

END_OF_INSTRUCTION
