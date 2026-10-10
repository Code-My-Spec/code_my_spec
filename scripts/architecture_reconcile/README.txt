One-off architecture record reconciliation

Run from the project root after compiling the desired source revision:

  mix run --no-compile --no-start scripts/architecture_reconcile/export_calls.exs /tmp/module-calls.json
  mix run --no-compile --no-start scripts/architecture_reconcile/reconcile.exs --database DATABASE --project PROJECT_UUID --copy COPY_UUID --user EMAIL --xref /tmp/module-calls.json --report /tmp/reconciliation-dry-run.json

Inspect the report, then repeat with --apply and a NEW report path. Repeat a
dry-run afterwards to verify zero differences. Reports cannot be overwritten.

The --xref input is module-call evidence, NOT mix xref graph file-level JSON.
Uses Boundary's compiled call/struct trace. Plain module references are excluded.
Preserves actual module identity, including multiple modules in one source file.
Writes through Components APIs in a transaction; saves prior records first.
Only reconciles existing components present in the compiled module inventory.
No application services or agent fleet are started.

Limitations:
- Snapshot represents the last compiled source. Compile before exporting.
- Dynamic calls cannot be inferred from module atoms. Alias-only references are
  retained in the report for review rather than becoming dependencies.
- Compiled modules without component records are reported, not attributed to
  their containing file's primary module. Outside-snapshot edges are preserved.
- Boundary's manifest format is dependency-specific.

Regression check:
  mix run --no-compile --no-start scripts/architecture_reconcile/extract_test.exs

Operational reports/backups stay in ignored tmp/architecture-reconcile/.
