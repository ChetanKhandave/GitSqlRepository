-- ============================================================================
-- Oracle 19c DML templates executed by the Java application.
-- Bind variables use :name notation for readability.
-- Hash comparison is performed in Java.
-- All state-changing scenario statements must execute in one transaction.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- COMMON LOOKUPS
-- ----------------------------------------------------------------------------

-- Read the current trusted hash for a customer.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = :custId;

-- Read the current pending hash and cooling-period boundary.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId;

-- Lock ACTIVE before any transaction that can change ACTIVE/PENDING state.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = :custId
FOR UPDATE;

-- Lock PENDING after ACTIVE to keep a consistent lock order and reduce deadlocks.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId
FOR UPDATE;

-- ----------------------------------------------------------------------------
-- SCENARIO 1: frontend verification failed
-- ----------------------------------------------------------------------------
-- No SQL operation is required.
-- Java returns authentication failure, shows existing ETB menu,
-- does not start cooling, does not schedule SMS, and does not report PRM.

-- ----------------------------------------------------------------------------
-- MALFORMED REQUEST
-- ----------------------------------------------------------------------------
-- Validate required fields in Java before accessing the database.
-- Return "Unable to serve your request." and perform no DB/SMS/PRM operation.

-- ----------------------------------------------------------------------------
-- SCENARIOS 2 AND 3: first verified passkey
-- ----------------------------------------------------------------------------
-- Insert the first trusted hash when ACTIVE_PASSKEY has no row for the customer.
INSERT INTO ACTIVE_PASSKEY
(
    CUST_ID,
    MOBILE_NUMBER,
    PASSKEY_HASH,
    UPDATED_TIME
)
VALUES
(
    :custId,
    :mobileNumber,
    :incomingHash,
    SYSTIMESTAMP AT TIME ZONE 'UTC'
);

-- ----------------------------------------------------------------------------
-- SCENARIO 4: incoming hash matches ACTIVE
-- ----------------------------------------------------------------------------
-- Read ACTIVE and compare PASSKEY_HASH in Java.
-- If there is no pending row, no DML is required.
-- If a pending row exists, execute Scenario 6 because the original trusted
-- device/passkey has been reconfirmed.

-- ----------------------------------------------------------------------------
-- COMMON: create a new pending verification cycle
-- Used by Scenarios 5, 8 and 10.
-- ----------------------------------------------------------------------------
-- The cooling start is stored once. COOLING_END_TIME is exactly +48 hours.
INSERT INTO PASSKEY_PENDING_VERIFICATION
(
    CUST_ID,
    PASSKEY_HASH,
    MOBILE_NUMBER,
    COOLING_START_TIME,
    COOLING_END_TIME
)
VALUES
(
    :custId,
    :incomingHash,
    :mobileNumber,
    SYSTIMESTAMP AT TIME ZONE 'UTC',
    (SYSTIMESTAMP AT TIME ZONE 'UTC') + NUMTODSINTERVAL(48, 'HOUR')
);

-- Create the four SMS rows from the exact cooling start stored in PENDING.
-- SMS 1 = immediate, SMS 2 = +15h, SMS 3 = +30h, SMS 4 = +46h.
INSERT INTO PASSKEY_SMS_SCHEDULE
(
    SMS_SCHEDULE_ID,
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
SELECT SEQ_PASSKEY_SMS_SCHEDULE.NEXTVAL,
       P.CUST_ID,
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

-- ----------------------------------------------------------------------------
-- SCENARIO 5: first mismatch
-- ----------------------------------------------------------------------------
-- Transaction:
--   1. Insert PENDING row.
--   2. Insert four SMS schedule rows.
--   3. Commit.
-- ACTIVE remains unchanged.

-- ----------------------------------------------------------------------------
-- COMMON: archive current PENDING row
-- ----------------------------------------------------------------------------
-- :archiveReason must be one of:
--   AR102 = active hash reconfirmed
--   AR103 = pending replaced during cooling
--   AR104 = pending replaced after cooling
INSERT INTO PASSKEY_ARCHIVAL
(
    ARCHIVAL_ID,
    CUST_ID,
    PASSKEY_HASH,
    SOURCE_TYPE,
    ORIGINAL_COOLING_START_TIME,
    ORIGINAL_COOLING_END_TIME,
    ARCHIVE_REASON,
    ARCHIVED_TIME
)
SELECT SEQ_PASSKEY_ARCHIVAL.NEXTVAL,
       CUST_ID,
       PASSKEY_HASH,
       'PENDING_VERIFICATION',
       COOLING_START_TIME,
       COOLING_END_TIME,
       :archiveReason,
       SYSTIMESTAMP AT TIME ZONE 'UTC'
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId;

-- ----------------------------------------------------------------------------
-- COMMON: cancel unsent SMS rows for the current cooling cycle
-- ----------------------------------------------------------------------------
-- Use the cooling start from the PENDING row fetched/locked by Java.
-- SENT rows remain unchanged for audit. PROCESSING requires provider-aware logic.
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

-- Remove current pending state after archival/cancellation is complete.
DELETE FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId;

-- ----------------------------------------------------------------------------
-- SCENARIO 6: original ACTIVE hash used during cooling
-- ----------------------------------------------------------------------------
-- Transaction:
--   1. Lock ACTIVE, then PENDING.
--   2. Archive PENDING using ARCHIVE_REASON='AR102'.
--   3. Cancel remaining PENDING/QUEUED SMS for that cooling cycle.
--   4. Delete PENDING row.
-- ACTIVE remains unchanged and authentication succeeds.

-- ----------------------------------------------------------------------------
-- SCENARIO 7: same PENDING hash during cooling
-- ----------------------------------------------------------------------------
-- Read cooling status. No state update is performed when the same pending hash
-- is retried before COOLING_END_TIME.
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

-- When incoming hash matches PENDING and COOLING_ACTIVE='Y':
--   * Do not reset cooling.
--   * Do not create another immediate SMS.
--   * Existing 15h/30h/46h SMS schedule continues.

-- ----------------------------------------------------------------------------
-- SCENARIO 8: different hash during cooling
-- ----------------------------------------------------------------------------
-- Transaction:
--   1. Lock ACTIVE, then PENDING.
--   2. Archive old PENDING using ARCHIVE_REASON='AR103'.
--   3. Cancel unsent SMS for old COOLING_START_TIME.
--   4. Delete old PENDING.
--   5. Insert new PENDING with new 48-hour cooling period.
--   6. Insert four new SMS schedule rows.
-- ACTIVE remains unchanged.

-- ----------------------------------------------------------------------------
-- SCENARIO 9: matching PENDING hash after cooling
-- ----------------------------------------------------------------------------
-- Archive the current ACTIVE hash before replacing it.
-- AR101 means previous ACTIVE was replaced after successful cooling.
INSERT INTO PASSKEY_ARCHIVAL
(
    ARCHIVAL_ID,
    CUST_ID,
    PASSKEY_HASH,
    SOURCE_TYPE,
    ORIGINAL_UPDATED_TIME,
    ARCHIVE_REASON,
    ARCHIVED_TIME
)
SELECT SEQ_PASSKEY_ARCHIVAL.NEXTVAL,
       CUST_ID,
       PASSKEY_HASH,
       'ACTIVE',
       UPDATED_TIME,
       'AR101',
       SYSTIMESTAMP AT TIME ZONE 'UTC'
FROM ACTIVE_PASSKEY
WHERE CUST_ID = :custId;

-- Replace ACTIVE with PENDING only when the 48-hour cooling period completed.
UPDATE ACTIVE_PASSKEY A
SET A.PASSKEY_HASH =
    (
        SELECT P.PASSKEY_HASH
        FROM PASSKEY_PENDING_VERIFICATION P
        WHERE P.CUST_ID = A.CUST_ID
          AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
    ),
    A.MOBILE_NUMBER =
    (
        SELECT P.MOBILE_NUMBER
        FROM PASSKEY_PENDING_VERIFICATION P
        WHERE P.CUST_ID = A.CUST_ID
          AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
    ),
    A.UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE A.CUST_ID = :custId
  AND EXISTS
    (
        SELECT 1
        FROM PASSKEY_PENDING_VERIFICATION P
        WHERE P.CUST_ID = A.CUST_ID
          AND (SYSTIMESTAMP AT TIME ZONE 'UTC') >= P.COOLING_END_TIME
    );

-- Java must verify exactly one ACTIVE row was updated.
-- Then cancel any remaining unsent SMS for the old cooling cycle and delete
-- the PENDING row. Do not archive the PENDING hash because it is now ACTIVE.

-- ----------------------------------------------------------------------------
-- SCENARIO 10: different hash after cooling
-- ----------------------------------------------------------------------------
-- Transaction:
--   1. Lock ACTIVE, then PENDING.
--   2. Archive old PENDING using ARCHIVE_REASON='AR104'.
--   3. Cancel unsent SMS for old COOLING_START_TIME.
--   4. Delete old PENDING.
--   5. Insert new PENDING with a fresh 48-hour cooling period.
--   6. Insert four fresh SMS schedule rows.
-- Existing ACTIVE remains unchanged.
