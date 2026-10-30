# Feedback loop and adding data sources

## How the loop works

1. **Triage.** The app shows the top 3 likely causes (`gold_real.triage_card`).
2. **Confirm.** After the repair, the technician picks the actual cause under the card (Triage tab, "Close the loop"). `POST /api/feedback` writes one row to `ultraviolet.gold_real.triage_feedback`. The backend computes the verdict (`top1` / `top3` / `missed`) and takes the technician's identity from the `X-Forwarded-Email` header.
3. **Re-learn.** The `repair-triage-agents` job runs every Monday at 06:00 CT.
   - Agent 1 reads every source through `silver_real.repair_lines_unified`. Technician feedback is one of those sources, so confirmed causes become new labeled lines (`source_system = 'Technician feedback'`) and flow through Agent 2's patterns.
   - If a technician enters an SAP order number that already has a cause code, SAP wins.
   - Feedback lines are excluded from the held-out evaluation (`eval_results`), which stays on SAP ground truth.
4. **Measure.** The Improve tab shows:
   - live top-1/top-3 from feedback, compared with the held-out benchmark
   - the data sources
   - `gold_real.improvement_backlog`, a live view that ranks:
     - families where the model is weak
     - vague-intake families
     - No Problem Found cost
     - missing manual sections
     - unmapped catalog prefixes
     - misses that technicians reported

`triage_feedback` is created once by `pipeline/setup_feedback.sql`, not by the job, so a job run never drops feedback. The app's service principal has `SELECT, MODIFY` on that table only.

The bundle's `dev` target pauses schedules on deploy. After `databricks bundle deploy`, unpause the job in the Jobs UI, or with `databricks jobs update` (set `schedule.pause_status` to `UNPAUSED`).

## Adding a data source (other product lines, past archives, future feeds)

Add one `UNION ALL` branch to `silver_real.repair_lines_unified` in `pipeline/agent1_extract.sql`. The branch maps the new table to the standard columns:

`source_system, order_number, line_number, catalog, part_description, serial_number, failure_details, probable_cause_code, parts_replaced, affected_areas, order_submit_date, received_date, repair_complete_date, net_price, sap_status, depot`

- **Other product lines.** If the catalog prefixes are new, add them to `lookup_family`; the Improve tab lists the biggest unmapped prefixes. If the new source uses different cause codes, extend `normalize_cause`.
- **Past data** (for example, pre-2023). It only adds history. The holdout stays "train before 2026, test on 2026".
- **Future data.** New rows are picked up by the weekly run. When a full new year exists, move the holdout cutoff in `agent2_patterns.sql` (`triage_patterns_train`) and `agent3_insights.sql` (`eval_results`) forward one year.
- **Never map PII fields.** Leave out `additional_information` and `internal_status_details`.
