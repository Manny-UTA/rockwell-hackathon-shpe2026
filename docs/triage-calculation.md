# How the triage percentages are calculated

This document explains every number on a triage card: the cause percentages, the confidence label,
the parts to stage, the areas to inspect, and the repeat-return warning. It also covers how the card's
accuracy is measured. All logic lives in SQL under `pipeline/` and runs in Databricks.

Figures in the examples come from the run on 2026-10-29.

---

## 1. Data structure

```
ultraviolet.shpe.sap_economy_repair_order_lines        raw SAP, 41,504 rows
        │
        ▼  Agent 1 · Extract (pipeline/agent1_extract.sql)
silver_real.repair_orders_clean   one row per order line (37,602), with family, symptom, serial, cleaned complaint
silver_real.repair_cause          one row per line per confirmed cause (15,482 labeled lines, 14 causes)
silver_real.repair_parts          one row per line per standardized part or affected area
        │
        ▼  Agent 2 · Patterns (pipeline/agent2_patterns.sql)
gold_real.triage_patterns         cause counts per group, at 4 levels of detail
gold_real.parts_by_cause          part / area counts per family and cause
gold_real.repeat_returns          latest completed repair per serial
gold_real.triage_card(...)        the function the app and Genie call
        │
        ▼  Agent 3 · Insights (pipeline/agent3_insights.sql)
gold_real.eval_results            2026 repairs scored with 2023–2025 patterns
```

### Fields Agent 1 derives for each order line

| Field | How it's derived | Function |
|---|---|---|
| `family` | Catalog prefix / bulletin, e.g. `R2711P…` → PanelView Plus, `R2094…` → Kinetix 6000 | `gold_real.lookup_family` |
| `failure_text` | Customer complaint with serial/PO boilerplate stripped, upper-cased | `gold_real.clean_failure_text` |
| `symptom` | Keyword rules → one of: No power, Display issue, Communication, Noise/vibration, Overheating, Intermittent, Physical damage, Fault code. **NULL = vague.** | `gold_real.classify_symptom` |
| `cause` | `probable_cause_code` split on commas and normalized to 14 categories (a line can have several) | `gold_real.normalize_cause` |

A line's symptom is set to NULL (vague) when:
- the complaint has no usable detail ("UNKNOWN", "DEFECTIVE", admin notes like "grey stock" or "recertify"), or
- the text contains the **technician's repair report** ("replaced bezel… passed all tests"). That describes the outcome,
  so using it would leak the answer (`gold_real.has_repair_notes`).

---

## 2. The pattern table

`gold_real.triage_patterns` counts, for every group of past repairs, how many had each cause.
Only **labeled** lines count, meaning lines with at least one confirmed cause.

| Column | Meaning |
|---|---|
| `level` | How specific the group is: `catalog+symptom`, `family+symptom`, `family`, or `all` |
| `catalog`, `family`, `symptom` | The group key (unused parts are NULL) |
| `cause` | One cause category |
| `cases` | Labeled lines in the group with this cause |
| `total` | Labeled lines in the group (any cause) |

```
share(cause) = cases / total × 100
```

Because a repair can have more than one confirmed cause, **the shares of a group can add up to more than 100%**.
Each percentage reads as "X% of similar past repairs had this cause".

---

## 3. Building a triage card, step by step

**Inputs:** catalog number, serial (optional), customer complaint (optional).

### Step 1 · Classify the incoming unit
Run the same functions Agent 1 uses, so new units are described exactly like historical ones:

```
family  = lookup_family(catalog)
symptom = classify_symptom(clean_failure_text(complaint))     -- may be NULL
```

### Step 2 · Back off to the most specific group with enough history
Check the levels in this order and use the **first one with `total ≥ 20`**:

| Priority | Level | Group key | Skipped when |
|---|---|---|---|
| 1 | `catalog+symptom` | same catalog **and** same symptom | symptom is NULL, or fewer than 20 cases |
| 2 | `family+symptom` | same family **and** same symptom | symptom is NULL, or fewer than 20 cases |
| 3 | `family` | same family | fewer than 20 cases |
| 4 | `all` | every labeled repair | never (always available) |

### Step 3 · Rank causes
Within the chosen group, rank causes by `cases` (ties broken alphabetically) and keep the top 3:

```
share_pct = round(cases / total × 100, 1)
n         = total          -- shown as "Based on n past cases"
```

### Step 4 · Confidence label
Based on the #1 cause and the group size:

| Label | Rule |
|---|---|
| **High** | level is not `all`, **and** `total ≥ 50`, **and** #1 share − #2 share **≥ 15 points** |
| **Medium** | level is not `all`, and `total ≥ 20` (but not High) |
| **Low** | fell back to `all` (no family history), or `total < 20` |

### Step 5 · Parts to stage and areas to inspect (ranked by lift)
Raw counts would always put covers and circuit boards on top, because they're replaced in almost every
refurbishment. Instead, items are ranked by **lift**: how much more common an item is for *this cause* than for the
family overall.

```
p_cause  = count(item, family, cause) / cases(family, cause)
p_family = count(item, family, any cause) / Σ cases(family, all causes)
lift     = p_cause / p_family
```

An item is eligible only when `count ≥ 5` and `p_cause ≥ 5%`. The top 3 by lift become `parts_to_stage`, and the
same is done for `areas_to_inspect`. Lift above 1 means the item is more typical of this cause than of the family
in general.

### Step 6 · Repeat-return warning
If the serial (leading zeros removed) has a completed repair in `gold_real.repeat_returns` **within the last 180
days**, the card shows the date, order, prior cause and parts replaced.

---

## 4. Worked example (real data)

**Input:** catalog `R2711PT15C22D9P/A`, no serial, complaint "Touchscreen not responding"

**Step 1:** family = **PanelView Plus**, cleaned text = `TOUCHSCREEN NOT RESPONDING`, symptom = **Display issue**

**Step 2:** back-off

| Level | Labeled cases (`total`) | Used? |
|---|---|---|
| catalog+symptom (R2711PT15C22D9P/A + Display issue) | 13 | ✗ under 20 |
| **family+symptom (PanelView Plus + Display issue)** | **339** | **✓** |
| family (PanelView Plus) | 2,214 | — |
| all | 15,482 | — |

**Step 3:** causes in the family+symptom group

| Rank | Cause | cases | total | share |
|---|---|---|---|---|
| 1 | Physical / Mechanical Damage | 163 | 339 | **48.1%** |
| 2 | Worn / End of Life | 129 | 339 | **38.1%** |
| 3 | Component Failure | 102 | 339 | **30.1%** |
| (4) | Contamination / Environmental | 60 | 339 | 17.7% |

163 / 339 = 0.481 → **48.1%**. The shares add up to more than 100% because many repairs have several causes.

**Step 4:** confidence: total = 339 (≥ 50 ✓), but 48.1 − 38.1 = **10.0 points** (< 15 ✗) → **Medium**

**Step 5:** parts to stage for Physical / Mechanical Damage (PanelView Plus: 968 lines with this cause, 3,419 cause-tagged lines in the family)

| Part | count | p_cause | p_family | lift |
|---|---|---|---|---|
| ICs / processor | 266 | 266 / 968 = 27.5% | 679 / 3,419 = 19.9% | **1.38** |
| Connectors / cables | 367 | 37.9% | 27.6% | **1.38** |
| Gaskets / seals | 62 | 6.4% | 4.8% | **1.33** |
| LCD / touchscreen | 727 | 75.1% | 71.4% | 1.05 |

→ Stage: **ICs / processor, Connectors / cables, Gaskets / seals**. LCD / touchscreen is replaced in 75% of these repairs,
but it's almost as common for every other PanelView cause, so it ranks lower.

**Resulting card**

| # | Cause | Share | Stage parts |
|---|---|---|---|
| 1 | Physical / Mechanical Damage | 48% | ICs / processor, Connectors / cables, Gaskets / seals |
| 2 | Worn / End of Life | 38% | Power supply, Housing / bezel / cover, LCD / touchscreen |
| 3 | Component Failure | 30% | Gaskets / seals, Circuit board (PCBA), LCD / touchscreen |

Medium confidence · based on 339 past cases matched at the family+symptom level.

To reproduce:

```sql
SELECT * FROM ultraviolet.gold_real.triage_card('R2711PT15C22D9P/A', NULL, 'Touchscreen not responding');
```

---

## 5. How accuracy is measured

Agent 3 simulates using the card in 2026 with only the history that existed before then:

1. Build `gold_real.triage_patterns_train` from repairs submitted **2023–2025 only**.
2. For every **2026** line with a confirmed cause (1,873 lines), predict the top 3 with the same back-off and ranking.
3. Compare with what the technician actually found:

| Metric | Formula | Result |
|---|---|---|
| **Top-1 accuracy** | % of lines where the #1 predicted cause is one of the actual causes | **61.0%** |
| **Top-3 accuracy** | % of lines where any of the top 3 is one of the actual causes | **86.4%** |
| **Baseline** | % of lines where "Component Failure" (the most common training cause) is an actual cause | **45.1%** |

**By confidence label** (does the label mean anything?)

| Confidence | Lines | Top-1 | Top-3 |
|---|---|---|---|
| High | 1,176 | 67.6% | 85.5% |
| Medium | 571 | 57.8% | 88.3% |
| Low | 126 | 13.5% | 86.5% |

Safeguards:
- No 2026 line is used to build the training patterns (checked: 0 overlap).
- Technician repair notes are excluded from symptom detection (Section 1), so the outcome can't leak into the prediction.
- Duplicate SAP order lines are removed, so each repair is scored once.

---

## 6. Known limitations

- Only ~40% of SAP lines have a confirmed cause, so the patterns come from about 15,500 repairs.
- About two thirds of complaints are vague, so most cards are built at the family level.
- `catalog+symptom` groups rarely reach 20 cases, so most specific matches fall back to family+symptom.
- Symptoms come from keyword rules, which can misread wording (e.g. "the HMI *displays* an error" → Display issue).
