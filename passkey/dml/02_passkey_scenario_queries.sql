-- ============================================================================
-- Oracle 19c DML templates executed by the Java application.
-- Bind variables use :name notation for readability.
-- ACTIVE is locked before PENDING for state-changing scenarios.
-- All current timestamps are generated explicitly in UTC.
-- ============================================================================

-- COMMON LOOKUPS -------------------------------------------------------------
-- Read current ACTIVE state, including the cooling window through which the
-- current hash became active. Cooling columns are NULL for first registration.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME,
       UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = :custId;

-- Read current PENDING state.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId;

-- Lock ACTIVE first.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME,
       UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = :custId
FOR UPDATE;

-- Lock PENDING only after ACTIVE.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId
FOR UPDATE;

-- SCENARIO 1 -----------------------------------------------------------------
-- Frontend verification failed: no SQL, no cooling, no SMS, no PRM.

-- MALFORMED REQUEST -----------------------------------------------------------
-- Validate in Java before DB access. Return "Unable to serve your request."

-- SCENARIOS 2 AND 3 -----------------------------------------------------------
-- First successful registration has never passed through cooling, therefore
-- ACTIVE.COOLING_START_TIME and ACTIVE.COOLING_END_TIME are stored as NULL.
INSERT INTO ACTIVE_PASSKEY
(
    CUST_ID,
    MOBILE_NUMBER,
    PASSKEY_HASH,
    COOLING_START_TIME,
    COOLING_END_TIME,
    UPDATED_TIME
)
VALUES
(
    :custId,
    :mobileNumber,
    :incomingHash,
    NULL,
    NULL,
    SYSTIMESTAMP AT TIME ZONE 'UTC'
);

-- SCENARIO 4 -----------------------------------------------------------------
-- If incoming hash matches ACTIVE and no PENDING exists, no DML is required.
-- If PENDING exists, execute Scenario 6.

-- COMMON: CREATE NEW PENDING --------------------------------------------------
INSERT INTO PASSKEY_PENDING_VERIFICATION
(
    CUST_ID,
    PASSKEY_HASH,
    MOBILE_NUMBER,
    COOLING_START_TIME,
    COOLING_END_TIME
)
SELECT :custId,
       :incomingHash,
       :mobileNumber,
       T.UTC_NOW,
       T.UTC_NOW + NUMTODSINTERVAL(48, 'HOUR')
FROM
(
    SELECT SYSTIMESTAMP AT TIME ZONE 'UTC' AS UTC_NOW
    FROM DUAL
) T;

-- Create SMS at 0h, 15h, 30h and 46h from exact stored cooling start.
INSERT INTO PASSKEY_SMS_SCHEDULE
(
    CUST_ID,
    MOBILE_NUMBER,
    COOLING_START_TIME,
    SMS_SEQUENCE,
    SCHEDULED_TIME,
    NEXT_ATTEMPT_TIME,
    SMS_STATUS,
    CREATED_TIME,
    UPDATED_TIME
)
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
CROSS JOIN
(
    SELECT 1 AS SMS_SEQUENCE FROM DUAL
    UNION ALL SELECT 2 FROM DUAL
    UNION ALL SELECT 3 FROM DUAL
    UNION ALL SELECT 4 FROM DUAL
) S
WHERE P.CUST_ID = :custId;

-- SCENARIO 5 -----------------------------------------------------------------
-- Lock ACTIVE, confirm no PENDING, insert PENDING, insert exactly 4 SMS, commit.

-- COMMON: ARCHIVE CURRENT PENDING --------------------------------------------
-- AR102 = ACTIVE reconfirmed, AR103 = replaced during cooling,
-- AR104 = replaced after cooling.
INSERT INTO PASSKEY_ARCHIVAL
(
    CUST_ID,
    PASSKEY_HASH,
    SOURCE_TYPE,
    ORIGINAL_COOLING_START_TIME,
    ORIGINAL_COOLING_END_TIME,
    ARCHIVE_REASON,
    ARCHIVED_TIME
)
SELECT CUST_ID,
       PASSKEY_HASH,
       'PENDING_VERIFICATION',
       COOLING_START_TIME,
       COOLING_END_TIME,
       :archiveReason,
       SYSTIMESTAMP AT TIME ZONE 'UTC'
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId;

-- COMMON: CANCEL UNSENT SMS ---------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'CANCELLED',
    CANCELLED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC',
    CANCEL_REASON = :cancelReason,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE CUST_ID = :custId
  AND COOLING_START_TIME = :coolingStartTime
  AND SMS_STATUS IN ('PENDING', 'QUEUED');

-- Delete only the exact PENDING cycle read/locked by Java.
DELETE FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId
  AND COOLING_START_TIME = :coolingStartTime;

-- SCENARIO 6 -----------------------------------------------------------------
-- ACTIVE hash reconfirmed while PENDING exists:
-- archive PENDING as AR102, cancel remaining SMS, delete PENDING, commit.

-- SCENARIO 7 -----------------------------------------------------------------
SELECT CUST_ID,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME,
       CASE
           WHEN (SYSTIMESTAMP AT TIME ZONE 'UTC') < COOLING_END_TIME THEN 'Y'
           ELSE 'N'
       END AS COOLING_ACTIVE
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId;
-- Matching PENDING during active cooling => no DML and no cooling reset.

-- SCENARIO 8 -----------------------------------------------------------------
-- Different hash during cooling:
-- archive old PENDING AR103, cancel SMS, delete PENDING, create new PENDING,
-- create 4 fresh SMS rows, commit. ACTIVE is unchanged.

-- SCENARIO 9 -----------------------------------------------------------------
-- Matching PENDING hash after cooling.
-- Step 1: archive existing ACTIVE. The ACTIVE row now retains its own activation
-- cooling window, so copy those values into archival before replacement.
INSERT INTO PASSKEY_ARCHIVAL
(
    CUST_ID,
    PASSKEY_HASH,
    SOURCE_TYPE,
    ORIGINAL_UPDATED_TIME,
    ORIGINAL_COOLING_START_TIME,
    ORIGINAL_COOLING_END_TIME,
    ARCHIVE_REASON,
    ARCHIVED_TIME
)
SELECT A.CUST_ID,
       A.PASSKEY_HASH,
       'ACTIVE',
       A.UPDATED_TIME,
       A.COOLING_START_TIME,
       A.COOLING_END_TIME,
       'AR101',
       SYSTIMESTAMP AT TIME ZONE 'UTC'
FROM ACTIVE_PASSKEY A
WHERE A.CUST_ID = :custId
  AND EXISTS
      (
          SELECT 1
          FROM PASSKEY_PENDING_VERIFICATION P
          WHERE P.CUST_ID = A.CUST_ID
            AND P.PASSKEY_HASH = :incomingHash
            AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
      );

-- Step 2: promote PENDING into ACTIVE and preserve the completed cooling window.
UPDATE ACTIVE_PASSKEY A
SET
(
    A.PASSKEY_HASH,
    A.MOBILE_NUMBER,
    A.COOLING_START_TIME,
    A.COOLING_END_TIME,
    A.UPDATED_TIME
) =
(
    SELECT P.PASSKEY_HASH,
           P.MOBILE_NUMBER,
           P.COOLING_START_TIME,
           P.COOLING_END_TIME,
           SYSTIMESTAMP AT TIME ZONE 'UTC'
    FROM PASSKEY_PENDING_VERIFICATION P
    WHERE P.CUST_ID = A.CUST_ID
      AND P.PASSKEY_HASH = :incomingHash
      AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
)
WHERE A.CUST_ID = :custId
  AND EXISTS
      (
          SELECT 1
          FROM PASSKEY_PENDING_VERIFICATION P
          WHERE P.CUST_ID = A.CUST_ID
            AND P.PASSKEY_HASH = :incomingHash
            AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
      );

-- Java must verify exactly one row archived and exactly one ACTIVE row updated.
-- Then cancel remaining SMS for the old PENDING cycle and delete PENDING.

-- SCENARIO 10 ----------------------------------------------------------------
-- Different hash after cooling:
-- archive old PENDING AR104, cancel SMS, delete PENDING, create new PENDING,
-- create 4 new SMS rows. Existing ACTIVE including its historical cooling window
-- remains unchanged.

-- TRANSACTION SUMMARY ---------------------------------------------------------
-- Scenario 5  : lock ACTIVE -> confirm no PENDING -> insert PENDING + 4 SMS.
-- Scenario 6  : lock ACTIVE -> lock PENDING -> archive/cancel/delete PENDING.
-- Scenario 7  : read-only.
-- Scenario 8  : archive/cancel/delete old PENDING -> new PENDING + 4 SMS.
-- Scenario 9  : archive ACTIVE (with its cooling window) -> promote PENDING
--               (including its cooling window) -> cancel SMS -> delete PENDING.
-- Scenario 10 : archive/cancel/delete old PENDING -> new PENDING + 4 SMS.
-- Any state-changing failure must cause JDBC rollback.
