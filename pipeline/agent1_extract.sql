-- =============================================================================
-- AGENT 1 - EXTRACT
-- Reads raw SAP repair order lines and structures them for Agent 2:
-- deduplicated lines, family, symptom, cleaned failure text, normalized serial, causes, parts, areas.
-- Part of the repair-triage-agents job: agent1_extract -> agent2_patterns -> agent3_insights.
-- Each agent logs what it handed off in ultraviolet.gold_real.agent_handoffs.
-- Statements are separated by lines containing only ';'.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ultraviolet.gold_real.agent_handoffs (
  run_at TIMESTAMP, agent STRING, output_table STRING, rows BIGINT, summary STRING
) COMMENT 'Run log: what each agent in the repair-triage-agents job handed to the next one'
;

-- ---------------------------------------------------------------------------
-- Family lookup from catalog number. PowerFlex rules require a letter after the
-- bulletin (20A, 22B, 25B...) so Kinetix 2093/2094/2097/2098/2099 aren't misread as PowerFlex.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ultraviolet.gold_real.lookup_family(p_catalog STRING)
RETURNS STRING
COMMENT 'Product family from catalog number (bulletin / series prefix)'
RETURN (WITH c AS (SELECT upper(regexp_replace(trim(coalesce(p_catalog,'')), '^(RPG|R)(?=[0-9A-Z])', '')) AS k)
SELECT CASE
  WHEN k = '' THEN NULL
  WHEN k RLIKE '^20A' THEN 'PowerFlex 70'
  WHEN k RLIKE '^20B' THEN 'PowerFlex 700'
  WHEN k RLIKE '^20[CDE]' THEN 'PowerFlex 700S/700H'
  WHEN k RLIKE '^20F' THEN 'PowerFlex 753'
  WHEN k RLIKE '^20G' THEN 'PowerFlex 755'
  WHEN k RLIKE '^20[A-Z]' THEN 'PowerFlex (other)'
  WHEN k RLIKE '^22[A-Z]' THEN 'PowerFlex 4/40'
  WHEN k RLIKE '^25[A-Z]' THEN 'PowerFlex 520'
  WHEN k RLIKE '^2094' THEN 'Kinetix 6000'
  WHEN k RLIKE '^2198' THEN 'Kinetix 5700'
  WHEN k RLIKE '^2099' THEN 'Kinetix 7000'
  WHEN k RLIKE '^2097' THEN 'Kinetix 300'
  WHEN k RLIKE '^2093' THEN 'Kinetix 2000'
  WHEN k RLIKE '^2098' THEN 'Ultra 3000/5000'
  WHEN k RLIKE '^1398' THEN 'Ultra 100/200'
  WHEN k RLIKE '^1394' THEN 'Ultra 1394'
  WHEN k RLIKE '^MP[LMFS]' THEN 'MP-Series Motor'
  WHEN k RLIKE '^VP[LCF]' THEN 'Kinetix VP Motor'
  WHEN k RLIKE '^1326' THEN '1326 Servo Motor'
  WHEN k RLIKE '^HPK' THEN 'HPK Servo Motor'
  WHEN k RLIKE '^2711P' THEN 'PanelView Plus'
  WHEN k RLIKE '^2711' THEN 'PanelView'
  WHEN k RLIKE '^(6181|6176|6186|6155)' THEN 'VersaView Industrial PC'
  WHEN k RLIKE '^1756' THEN 'ControlLogix'
  WHEN k RLIKE '^1769' THEN 'CompactLogix'
  WHEN k RLIKE '^174[67]' THEN 'SLC 500'
  WHEN k RLIKE '^1771' THEN 'PLC-5 I/O'
  WHEN k RLIKE '^1785' THEN 'PLC-5'
  WHEN k RLIKE '^1794' THEN 'FLEX I/O'
  WHEN k RLIKE '^1734' THEN 'POINT I/O'
  WHEN k RLIKE '^1791' THEN 'Guard I/O'
  WHEN k RLIKE '^1336' THEN '1336 Drive'
  WHEN k RLIKE '^150' THEN 'SMC Soft Starter'
  WHEN k RLIKE '^442' THEN 'Safety Scanner'
  ELSE concat('Other ', coalesce(nullif(regexp_extract(k, '^([0-9]+|[A-Z]+)', 1), ''), k))
END FROM c)
;

-- ---------------------------------------------------------------------------
-- Symptom classifier (rule-based, deterministic; same labels as the mock + Overheating)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ultraviolet.gold_real.classify_symptom(p_clean STRING)
RETURNS STRING
COMMENT 'Rule-based symptom from cleaned failure text (see clean_failure_text). NULL = vague / no usable symptom.'
RETURN CASE
  WHEN ultraviolet.gold_real.is_vague_text(p_clean) THEN NULL
  -- administrative / non-failure reasons
  WHEN p_clean RLIKE 'GREY STOCK|RECERTIF|INVENTORY|LAST TIME BUY|PRODUCT NOTICE|PSA PN|RECALL|REWORK PROJECT|SWITCH ORDER|EXCHANGE|REPLACED WITH A NEW UNIT|PREVENTATIVE MAINT|REMAN|REFURB|REBUILD|NEEDS (CHECKED|REPAIRED)|RETURNED DEFECTIVE FROM STORES|UPGRADE ONLY|TMP UPGRADE' THEN NULL
  WHEN p_clean RLIKE '(WILL NOT|WONT|WON T|DOES NOT|DOESN T|DOESNT|CANNOT|CAN T|NOT) (POWER|TURN ON|BOOT|START UP)|NO POWER|\\bDEAD\\b|NO LED|NO LIGHTS?\\b|NOT POWERING|NO OUTPUT' THEN 'No power'
  WHEN p_clean RLIKE 'DISPLAY|SCREEN|TOUCH|BACKLIGHT|\\bLCD\\b|PIXEL|BLANK|FLICKER|\\bDIM\\b|LINES ON' THEN 'Display issue'
  WHEN p_clean RLIKE 'COMM|ETHERNET|NETWORK|DEVICENET|CONTROLNET|SERCOS|NOT RECOGNI|NOT DETECT|NO CONNECT|CONNECTION|\\bPORT\\b' THEN 'Communication'
  WHEN p_clean RLIKE 'NOIS|VIBRAT|GRIND|LOUD|BEARING|ROUGH|SHAFT|SEIZED|LOCKED UP|STUCK|BRAKE' THEN 'Noise/vibration'
  WHEN p_clean RLIKE 'OVERHEAT|OVER HEAT|OVER ?TEMP|GETS HOT|RUNS HOT|TOO HOT|THERMAL' THEN 'Overheating'
  WHEN p_clean RLIKE 'INTERMIT|SOMETIMES|RANDOM|ON AND OFF|OCCASIONAL|SPORADIC|ERRATIC' THEN 'Intermittent'
  WHEN p_clean RLIKE 'BROKEN|DAMAGE|CRACK|BURN|SMOKE|WATER|LIQUID|MELT|PHYSICAL|DROPPED|SPARK|CORRO|\\bFIRE\\b|BLOWN|EXPLOD' THEN 'Physical damage'
  WHEN p_clean RLIKE 'FAULT|ERROR|ALARM|\\bCODE\\b|TRIP|OVER ?CURRENT|OVER ?VOLT|OVER ?LOAD|SHORT|GROUND|\\bE ?[0-9]{2,3}\\b|\\bF ?[0-9]{1,3}\\b|ENCODER|FEEDBACK|FLASHING|RED LIGHT' THEN 'Fault code'
  ELSE NULL
END
;

-- ---------------------------------------------------------------------------
-- Repair-notes detector. About 5% of SAP failure_details contain the technician's repair report
-- (parts changed, tests passed) instead of / before the customer complaint. Those words describe
-- the outcome, so using them as a symptom would leak the answer into triage and the evaluation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ultraviolet.gold_real.has_repair_notes(p_text STRING)
RETURNS BOOLEAN
COMMENT 'TRUE when failure text contains technician repair-report language (post-repair findings), not just a customer complaint'
RETURN coalesce(upper(p_text) RLIKE 'TESTED (OK|GOOD|FINE)|UNIT TESTED|PASSED (ALL |INITIAL |RESISTANCE |FUNCTIONAL )*TESTS?|FAILED HI.?POT|REPLACED .{0,40}(BOARD|BEZEL|FAN|CAP|BEARING|DISPLAY|LCD|IGBT|MODULE|CONNECTOR|HARNESS|ENCODER)|CHANGED PARTS|UPDATED (UNIT|FIRMWARE|F/W)|F/W REV|H/W REV|SERIES IN [A-Z]|SHOT ?BLASTED|RE-?PAINTED|VISUALLY INSPECTED|UNIT RECEIVED', FALSE)
;

-- ---------------------------------------------------------------------------
-- Silver: cleaned order lines
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.silver_real.repair_orders_clean
COMMENT 'Real data (Agent 1): one row per SAP repair order line (deduplicated) with family, rule-based symptom, normalized serial, raw cause/parts/areas. Built by pipeline/build_real_tables.sql'
AS
WITH src AS (
  SELECT *, ultraviolet.gold_real.clean_failure_text(failure_details) AS clean
  FROM ultraviolet.shpe.sap_economy_repair_order_lines
  WHERE catalog IS NOT NULL
    AND NOT upper(catalog) RLIKE 'PROXY|^CUSTOMER\\.|REFORM'      -- service SKUs, not hardware
  -- The source repeats some (order_number, line_number) keys; keep the most complete copy
  QUALIFY row_number() OVER (
    PARTITION BY order_number, line_number
    ORDER BY probable_cause_code IS NULL, parts_replaced IS NULL, repair_complete_date DESC NULLS LAST, sap_status
  ) = 1
)
SELECT
  order_number,
  CAST(line_number AS INT)                                   AS line_number,
  upper(trim(catalog))                                       AS catalog,
  ultraviolet.gold_real.lookup_family(catalog)               AS family,
  CASE WHEN NOT ultraviolet.gold_real.has_repair_notes(failure_details)
       THEN ultraviolet.gold_real.classify_symptom(clean) END AS symptom,
  ultraviolet.gold_real.has_repair_notes(failure_details) OR ultraviolet.gold_real.classify_symptom(clean) IS NULL AS is_vague,
  ultraviolet.gold_real.has_repair_notes(failure_details)    AS has_repair_notes,
  nullif(regexp_replace(upper(trim(serial_number)), '^0+', ''), '') AS serial,
  order_submit_date                                          AS submit_date,
  received_date,
  CAST(repair_complete_date AS DATE)                         AS repair_complete_date,
  nullif(clean, '')                                          AS failure_text,
  net_price,
  part_description,
  sap_status,
  depot,
  -- original report fields, kept so downstream agents / the simulator never need the raw table
  trim(regexp_replace(failure_details, '(?i)(PO[: ]*)[A-Z0-9-]+', '$1•••')) AS raw_failure_details,
  serial_number AS raw_serial_number,
  probable_cause_code AS raw_cause_code,
  parts_replaced,
  affected_areas
FROM src
;

-- ---------------------------------------------------------------------------
-- Silver: normalized causes (multi-label: one row per line per cause)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.silver_real.repair_cause
COMMENT 'Real data (Agent 1): normalized probable causes, one row per order line per cause'
AS
SELECT DISTINCT o.order_number, o.line_number, ultraviolet.gold_real.normalize_cause(trim(c)) AS cause
FROM ultraviolet.silver_real.repair_orders_clean o
LATERAL VIEW explode(split(o.raw_cause_code, ',')) t AS c
WHERE trim(c) != '' AND ultraviolet.gold_real.normalize_cause(trim(c)) IS NOT NULL
;

-- ---------------------------------------------------------------------------
-- Silver: parts and affected areas per line
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE ultraviolet.silver_real.repair_parts
COMMENT 'Real data: standardized part types replaced and affected areas, one row per order line per item (kind = part | area)'
AS
WITH s AS (
  SELECT order_number, line_number, upper(parts_replaced) AS parts, affected_areas
  FROM ultraviolet.silver_real.repair_orders_clean
),
part_map AS (
  SELECT * FROM VALUES
    ('Bearings',                 'BEARING|\\bBRG\\b'),
    ('Encoder / resolver',       'ENCODER|RESOLVER|TRANSDUCER'),
    ('Cooling fan',              '\\bFANS?\\b'),
    ('Capacitors',               '\\bCAPS?\\b|CAPACITOR|ELCO'),
    ('IGBT / power module',      'IGBT|POWER MOD|\\bTHY|\\bSCR\\b|RECTIFIER'),
    ('Circuit board (PCBA)',     'PCBA|\\bPCB\\b|\\bBOARD\\b|\\bBD\\b'),
    ('LCD / touchscreen',        '\\bLCD\\b|\\bDISP|BACKLIGHT|TOUCH'),
    ('Battery',                  'BTRY|BATTERY'),
    ('Gaskets / seals',          'GASKET|\\bSEALS?\\b|O-?RING'),
    ('Connectors / cables',      '\\bCONN|RIBBON|CABLE|HARNESS'),
    ('Brake',                    'BRAKE'),
    ('Fuse',                     '\\bFUSE'),
    ('Relay',                    'RELAY'),
    ('Resistors',                '\\bRES\\b|RESISTOR'),
    ('ICs / processor',          '\\bIC\\b|\\bDSP\\b|PROCESSOR|EPROM|FPGA|MEMORY'),
    ('Rotor / stator',           'ROTOR|STATOR'),
    ('Power supply',             'DCDC|POWER SUPPLY|\\bPSU\\b'),
    ('Housing / bezel / cover',  'BEZEL|\\bCOVER|HOUSING|END ?CAP|ENDBELL|PLASTIC')
    AS t(part, re)
)
SELECT DISTINCT s.order_number, s.line_number, 'part' AS kind, m.part AS item
FROM s JOIN part_map m ON s.parts RLIKE m.re
UNION ALL
SELECT DISTINCT s.order_number, s.line_number, 'area' AS kind, trim(a) AS item
FROM s LATERAL VIEW explode(split(s.affected_areas, ',')) t AS a
WHERE trim(a) != ''
;

INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '1 Extract', 'silver_real.repair_orders_clean', (SELECT count(*) FROM ultraviolet.silver_real.repair_orders_clean), (SELECT concat(format_number(count(*), 0), ' order lines from ', format_number((SELECT count(*) FROM ultraviolet.shpe.sap_economy_repair_order_lines), 0), ' raw SAP rows; ', format_number(count_if(NOT is_vague), 0), ' with a usable symptom; ', format_number(count_if(has_repair_notes), 0), ' with technician notes held out of symptom; ', format_number(count(DISTINCT family), 0), ' product families') FROM ultraviolet.silver_real.repair_orders_clean)
;
INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '1 Extract', 'silver_real.repair_cause', (SELECT count(*) FROM ultraviolet.silver_real.repair_cause), (SELECT concat(format_number(count(DISTINCT order_number, line_number), 0), ' lines with a confirmed cause; ', format_number(count(DISTINCT cause), 0), ' cause categories') FROM ultraviolet.silver_real.repair_cause)
;
INSERT INTO ultraviolet.gold_real.agent_handoffs
SELECT current_timestamp(), '1 Extract', 'silver_real.repair_parts', (SELECT count(*) FROM ultraviolet.silver_real.repair_parts), (SELECT concat(format_number(count_if(kind = 'part'), 0), ' part replacements, ', format_number(count_if(kind = 'area'), 0), ' affected-area records') FROM ultraviolet.silver_real.repair_parts)
;
