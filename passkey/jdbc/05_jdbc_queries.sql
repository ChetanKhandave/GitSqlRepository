-- ============================================================================
-- JDBC-ready Oracle 19c SQL for the passkey feature.
--
-- IMPORTANT JDBC NOTES
--   1. All bind parameters use positional '?' placeholders.
--   2. Parameter order is documented above every statement.
--   3. Hash comparison is performed in Java. Scenario 9 also verifies the
--      incoming hash in SQL as defense-in-depth before promotion.
--   4. Use Connection#setAutoCommit(false) for state-changing scenarios.
--   5. Commit only after every statement in the scenario succeeds.
--   6. Roll back the complete transaction on failure/unexpected row count.
--   7. When both rows are required, lock ACTIVE first and then PENDING.
-- ============================================================================

-- JQ01 - READ ACTIVE PASSKEY
-- Parameters: 1=CUST_ID. Expected result: 0 or 1 row.
SELECT CUST_ID, MOBILE_NUMBER, PASSKEY_HASH, UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = ?;

-- JQ02 - READ PENDING PASSKEY
-- Parameters: 1=CUST_ID. Expected result: 0 or 1 row.
SELECT CUST_ID, MOBILE_NUMBER, PASSKEY_HASH,
       COOLING_START_TIME, COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = ?;

-- JQ03 - LOCK ACTIVE PASSKEY
-- Parameters: 1=CUST_ID. Expected result: 1 row when ACTIVE exists.
SELECT CUST_ID, MOBILE_NUMBER, PASSKEY_HASH, UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = ?
FOR UPDATE;

-- JQ04 - LOCK PENDING PASSKEY
-- Lock only after JQ03 to keep a consistent lock order.
-- Parameters: 1=CUST_ID. Expected result: 0 or 1 row.
SELECT CUST_ID, MOBILE_NUMBER, PASSKEY_HASH,
       COOLING_START_TIME, COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = ?
FOR UPDATE;

-- JQ05 - INSERT FIRST ACTIVE PASSKEY (Scenarios 2/3)
-- Parameters: 1=CUST_ID, 2=MOBILE_NUMBER, 3=PASSKEY_HASH.
-- Expected update count: 1.
INSERT INTO ACTIVE_PASSKEY
(CUST_ID, MOBILE_NUMBER, PASSKEY_HASH, UPDATED_TIME)
VALUES (?, ?, ?, SYSTIMESTAMP AT TIME ZONE 'UTC');

-- JQ06 - INSERT NEW PENDING PASSKEY (Scenarios 5/8/10)
-- Generates COOLING_START_TIME once in Oracle and derives +48 hours from it.
-- Parameters: 1=CUST_ID, 2=PASSKEY_HASH, 3=MOBILE_NUMBER.
-- Expected update count: 1.
INSERT INTO PASSKEY_PENDING_VERIFICATION
(CUST_ID, PASSKEY_HASH, MOBILE_NUMBER, COOLING_START_TIME, COOLING_END_TIME)
SELECT ?, ?, ?, UTC_NOW, UTC_NOW + NUMTODSINTERVAL(48, 'HOUR')
FROM (
    SELECT SYSTIMESTAMP AT TIME ZONE 'UTC' AS UTC_NOW
    FROM DUAL
);

-- JQ07 - INSERT FOUR SMS SCHEDULE ROWS FOR THE CURRENT PENDING CYCLE
-- SMS 1=immediate, 2=+15h, 3=+30h, 4=+46h.
-- SMS_SCHEDULE_ID is GENERATED ALWAYS AS IDENTITY.
-- Parameters: 1=CUST_ID. Expected update count: 4.
INSERT INTO PASSKEY_SMS_SCHEDULE
(CUST_ID, MOBILE_NUMBER, COOLING_START_TIME, SMS_SEQUENCE,
 SCHEDULED_TIME, NEXT_ATTEMPT_TIME, SMS_STATUS, CREATED_TIME, UPDATED_TIME)
SELECT P.CUST_ID,
       P.MOBILE_NUMBER,
       P.COOLING_START_TIME,
       S.SMS_SEQUENCE,
       CASE S.SMS_SEQUENCE
           WHEN 1 THEN P.COOLING_START_TIME
           WHEN 2 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(15, 'HOUR')
           WHEN 3 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(30, 'HOUR')
           WHEN 4 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(46, 'HOUR')
       END,
       CASE S.SMS_SEQUENCE
           WHEN 1 THEN P.COOLING_START_TIME
           WHEN 2 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(15, 'HOUR')
           WHEN 3 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(30, 'HOUR')
           WHEN 4 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(46, 'HOUR')
       END,
       'PENDING',
       SYSTIMESTAMP AT TIME ZONE 'UTC',
       SYSTIMESTAMP AT TIME ZONE 'UTC'
FROM PASSKEY_PENDING_VERIFICATION P
CROSS JOIN (
    SELECT 1 AS SMS_SEQUENCE FROM DUAL
    UNION ALL SELECT 2 FROM DUAL
    UNION ALL SELECT 3 FROM DUAL
    UNION ALL SELECT 4 FROM DUAL
) S
WHERE P.CUST_ID = ?;

-- JQ08 - ARCHIVE CURRENT PENDING PASSKEY
-- AR102=ACTIVE reconfirmed; AR103=replaced during cooling;
-- AR104=replaced after cooling. ARCHIVAL_ID is identity-generated.
-- Parameters: 1=ARCHIVE_REASON, 2=CUST_ID. Expected update count: 1.
INSERT INTO PASSKEY_ARCHIVAL
(CUST_ID, PASSKEY_HASH, SOURCE_TYPE,
 ORIGINAL_COOLING_START_TIME, ORIGINAL_COOLING_END_TIME,
 ARCHIVE_REASON, ARCHIVED_TIME)
SELECT CUST_ID,
       PASSKEY_HASH,
       'PENDING_VERIFICATION',
       COOLING_START_TIME,
       COOLING_END_TIME,
       ?,
       SYSTIMESTAMP AT TIME ZONE 'UTC'
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = ?;

-- JQ09 - ARCHIVE CURRENT ACTIVE PASSKEY AS AR101 (Scenario 9)
-- Archives ACTIVE only if the incoming hash matches PENDING and cooling ended.
-- Parameters: 1=CUST_ID, 2=INCOMING_HASH. Expected update count: 1.
INSERT INTO PASSKEY_ARCHIVAL
(CUST_ID, PASSKEY_HASH, SOURCE_TYPE,
 ORIGINAL_UPDATED_TIME, ARCHIVE_REASON, ARCHIVED_TIME)
SELECT A.CUST_ID,
       A.PASSKEY_HASH,
       'ACTIVE',
       A.UPDATED_TIME,
       'AR101',
       SYSTIMESTAMP AT TIME ZONE 'UTC'
FROM ACTIVE_PASSKEY A
WHERE A.CUST_ID = ?
  AND EXISTS (
      SELECT 1
      FROM PASSKEY_PENDING_VERIFICATION P
      WHERE P.CUST_ID = A.CUST_ID
        AND P.PASSKEY_HASH = ?
        AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
  );

-- JQ10 - PROMOTE PENDING HASH TO ACTIVE (Scenario 9)
-- SQL again verifies incoming hash and cooling completion.
-- Parameters: 1=INCOMING_HASH, 2=CUST_ID, 3=INCOMING_HASH.
-- Expected update count: 1; otherwise roll back.
UPDATE ACTIVE_PASSKEY A
SET (A.PASSKEY_HASH, A.MOBILE_NUMBER, A.UPDATED_TIME) =
    (
        SELECT P.PASSKEY_HASH,
               P.MOBILE_NUMBER,
               SYSTIMESTAMP AT TIME ZONE 'UTC'
        FROM PASSKEY_PENDING_VERIFICATION P
        WHERE P.CUST_ID = A.CUST_ID
          AND P.PASSKEY_HASH = ?
          AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
    )
WHERE A.CUST_ID = ?
  AND EXISTS (
      SELECT 1
      FROM PASSKEY_PENDING_VERIFICATION P
      WHERE P.CUST_ID = A.CUST_ID
        AND P.PASSKEY_HASH = ?
        AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
  );

-- JQ11 - CANCEL UNSENT SMS FOR ONE COOLING CYCLE
-- SENT rows remain for audit. PROCESSING rows require provider-aware handling.
-- Parameters: 1=CANCEL_REASON, 2=CUST_ID, 3=COOLING_START_TIME.
-- Expected update count: 0..4.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'CANCELLED',
    CANCELLED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC',
    CANCEL_REASON = ?,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE CUST_ID = ?
  AND COOLING_START_TIME = ?
  AND SMS_STATUS IN ('PENDING', 'QUEUED');

-- JQ12 - DELETE CURRENT PENDING ROW
-- Parameters: 1=CUST_ID. Expected update count: 1 for Scenarios 6/8/9/10.
DELETE FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = ?;

-- JQ13 - READ COOLING STATUS
-- Parameters: 1=CUST_ID. Expected result: 0 or 1 row.
SELECT CUST_ID,
       PASSKEY_HASH,
       MOBILE_NUMBER,
       COOLING_START_TIME,
       COOLING_END_TIME,
       CASE
           WHEN (SYSTIMESTAMP AT TIME ZONE 'UTC') < COOLING_END_TIME
               THEN 'ACTIVE'
           ELSE 'COMPLETED'
       END AS COOLING_STATUS
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = ?;

-- ============================================================================
-- JDBC TRANSACTION FLOW BY BUSINESS SCENARIO
-- ============================================================================
-- Scenario 1:
--   No SQL.
--
-- Scenarios 2/3:
--   JQ01 -> if no ACTIVE, JQ05 (expect 1) -> COMMIT.
--
-- Scenario 4:
--   JQ01 -> compare incomingHash with ACTIVE in Java.
--   JQ02 -> if no PENDING, no DML. If PENDING exists, use Scenario 6 flow.
--
-- Scenario 5 (first mismatch):
--   BEGIN TX -> JQ03 -> JQ04(confirm no PENDING) -> JQ06(expect 1)
--   -> JQ07(expect 4) -> COMMIT.
--
-- Scenario 6 (ACTIVE hash used while PENDING exists):
--   BEGIN TX -> JQ03 -> JQ04(save COOLING_START_TIME)
--   -> JQ08(AR102, expect 1) -> JQ11 -> JQ12(expect 1) -> COMMIT.
--
-- Scenario 7 (same PENDING hash during cooling):
--   JQ01 + JQ13. If incomingHash matches PENDING and status=ACTIVE, no DML.
--
-- Scenario 8 (different hash during cooling):
--   BEGIN TX -> JQ03 -> JQ04(save old COOLING_START_TIME)
--   -> JQ08(AR103, expect 1) -> JQ11 -> JQ12(expect 1)
--   -> JQ06(expect 1) -> JQ07(expect 4) -> COMMIT.
--
-- Scenario 9 (matching PENDING hash after cooling):
--   BEGIN TX -> JQ03 -> JQ04(save COOLING_START_TIME)
--   -> verify hash/cooling in Java -> JQ09(expect 1) -> JQ10(expect 1)
--   -> JQ11 -> JQ12(expect 1) -> COMMIT.
--
-- Scenario 10 (different hash after cooling):
--   BEGIN TX -> JQ03 -> JQ04(save old COOLING_START_TIME)
--   -> JQ08(AR104, expect 1) -> JQ11 -> JQ12(expect 1)
--   -> JQ06(expect 1) -> JQ07(expect 4) -> COMMIT.
--
-- Any failed statement or unexpected mandatory update count => ROLLBACK.
