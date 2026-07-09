# shellcheck shell=bash
# Notebooks + frame cells — the full agent flow via the CLI: create a
# notebook, add frame cells, run them, and read the captured outputs
# with provenance. Outputs live in cell_runs, never in doc blocks, so
# get-doc stays lean; execution failures are recorded runs, refusals
# are error envelopes and nothing records.
#
# REQUIRES the CLI release that ships the notebook verbs (../cli):
#   create-doc --kind notebook
#   run-cell  <doc-slug> <block-id> [--actor human|agent]   → POST .../cells/:block_id/run
#   list-runs <doc-slug> <block-id> [--limit N]             → GET  .../cells/:block_id/runs
# Until that release lands, this file fails at the first run_cli call
# with "unknown command" — the server side is already live.

nb_db_template() {
  echo "postgres://${PGUSER:-postgres}:<password>@${PGHOST:-localhost}/${E2E_DB_NAME:-aveline_e2e}"
}

nb_db_password() { echo "${PGPASSWORD:-postgres}"; }

nb_mk_source() { # ws, name
  run_cli -w "$1" create-data-source --name "$2" \
    --url "$(nb_db_template)" --password "$(nb_db_password)"
}

block_frame() { # name, input-json, ops-json (optional)
  jq -nc --arg name "$1" --argjson input "$2" --argjson ops "${3:-[]}" \
    '{type: "frame", name: $name, input: $input, ops: $ops}'
}

orders_input() { # source-name
  jq -nc --arg source "$1" \
    --arg query "select * from (values ('emea', 50), ('amer', 250)) as t(region, amount)" \
    '{source: $source, query: $query}'
}

# Create a notebook with one source-backed frame ("orders") and echo
# "slug<newline>block_id".
nb_mk_notebook() { # ws
  local ws="$1"
  run_cli -w "$ws" create-doc --title "Orders notebook $(us n)" --kind notebook \
    --blocks "[$(block_frame orders "$(orders_input selfdb)")]"
  local slug; slug="$(jq -r '.slug' <<<"$LAST_OUT_TEXT")"
  run_cli -w "$ws" get-doc "$slug"
  printf "%s\n%s\n" "$slug" "$(jq -r '.doc.blocks[0].id' <<<"$LAST_OUT_TEXT")"
}

test_notebook_agent_flow_end_to_end() {
  local ws; ws="$(mk_workspace nb-flow)"
  nb_mk_source "$ws" selfdb

  local lines slug orders_id
  lines="$(nb_mk_notebook "$ws")"
  slug="$(sed -n 1p <<<"$lines")"
  orders_id="$(sed -n 2p <<<"$lines")"

  # Add a dependent frame cell via apply-ops — edits mint versions.
  local top; top="$(block_frame top '{"frame": "orders"}' \
    '[{"op": "sort", "by": [{"col": "amount", "dir": "desc"}]}, {"op": "head", "n": 1}]')"
  run_cli -w "$ws" apply-ops "$slug" --intent "add top frame" \
    --ops "[$(jq -nc --argjson b "$top" '{op: "append_block", block: $b}')]"
  expect_ok "append dependent frame cell"
  expect_eq ".version_number" "2" "editing source minted v2"

  # Run the upstream cell — captured output + provenance in the echo.
  run_cli -w "$ws" run-cell "$slug" "$orders_id"
  expect_ok "run-cell orders ok"
  expect_eq '.run.status' "ok" "run recorded as ok"
  expect_eq '.run.outputs.columns[0]' "region" "captured columns"
  expect_eq '.run.outputs.rows | length' "2" "captured rows"
  expect_eq '.run.actor.type' "agent" "provenance: actor type"
  expect_eq '.run.doc_version_number' "2" "provenance: version it ran against"
  expect_present '.run.snapshot_hash' "provenance: snapshot hash"
  expect_present '.run.duration_ms' "provenance: duration"

  # The dependent binds through the upstream's CAPTURED run.
  run_cli -w "$ws" get-doc "$slug"
  local top_id; top_id="$(jq -r '.doc.blocks[1].id' <<<"$LAST_OUT_TEXT")"
  run_cli -w "$ws" run-cell "$slug" "$top_id"
  expect_ok "run-cell top ok"
  expect_eq '.run.status' "ok" "dependent run ok"
  expect_eq '.run.outputs.rows[0][1]' "250" "pipeline kept the top row"

  # Outputs are NEVER written into doc blocks — reads stay lean.
  run_cli -w "$ws" get-doc "$slug"
  expect_absent '.doc.blocks[0].result' "no result echo on the block"
  expect_absent '.doc.blocks[0].outputs' "no outputs on the block"

  # Run history: newest first, --limit caps.
  run_cli -w "$ws" run-cell "$slug" "$orders_id"
  run_cli -w "$ws" list-runs "$slug" "$orders_id"
  expect_ok "list-runs ok"
  expect_eq '.runs | length' "2" "both runs listed"
  expect_eq '.runs[0].status' "ok" "runs carry status"
  run_cli -w "$ws" list-runs "$slug" "$orders_id" --limit 1
  expect_eq '.runs | length' "1" "--limit caps the list"
}

test_run_cell_refusals_record_nothing() {
  local ws; ws="$(mk_workspace nb-refuse)"
  nb_mk_source "$ws" selfdb

  # Not a notebook → machine-readable refusal.
  local doc; doc="$(mk_doc "$ws" "Plain doc")"
  run_cli -w "$ws" run-cell "$doc" b_anything
  expect_err "not_notebook" 2 "kind=doc refuses with not_notebook"

  local lines slug orders_id
  lines="$(nb_mk_notebook "$ws")"
  slug="$(sed -n 1p <<<"$lines")"
  orders_id="$(sed -n 2p <<<"$lines")"

  run_cli -w "$ws" run-cell "$slug" b_ghost
  expect_err "cell_not_found" 4 "unknown cell refuses with cell_not_found"

  run_cli -w "$ws" run-cell "$slug" "$orders_id" --actor bogus
  expect_err "invalid_actor" 2 "bogus actor refused before anything executes"

  run_cli -w "$ws" list-runs "$slug" "$orders_id"
  expect_eq '.runs | length' "0" "refusals recorded no runs"
}

test_unrun_upstream_is_an_error_run_not_a_crash() {
  local ws; ws="$(mk_workspace nb-upstream)"
  nb_mk_source "$ws" selfdb

  local lines slug
  lines="$(nb_mk_notebook "$ws")"
  slug="$(sed -n 1p <<<"$lines")"

  local top; top="$(block_frame top '{"frame": "orders"}')"
  run_cli -w "$ws" apply-ops "$slug" --intent "add dependent" \
    --ops "[$(jq -nc --argjson b "$top" '{op: "append_block", block: $b}')]"

  run_cli -w "$ws" get-doc "$slug"
  local top_id; top_id="$(jq -r '.doc.blocks[1].id' <<<"$LAST_OUT_TEXT")"

  # Running the dependent never implicitly runs its upstream — the
  # failure is a RECORDED run with provenance, not an error envelope.
  run_cli -w "$ws" run-cell "$slug" "$top_id"
  expect_ok "dependent run returns a run"
  expect_eq '.run.status' "error" "status is error"
  if jq -e '.run.outputs.error | test("has not been run")' <<<"$LAST_OUT_TEXT" >/dev/null 2>&1; then
    pass "error names the unrun upstream"
  else
    fail "expected the unrun-upstream message in outputs.error"
  fi

  run_cli -w "$ws" list-runs "$slug" "$top_id"
  expect_eq '.runs | length' "1" "the error run is history too"
}
