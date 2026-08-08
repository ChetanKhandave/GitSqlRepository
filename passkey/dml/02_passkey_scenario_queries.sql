-- ============================================================================
-- Oracle 19c DML templates executed by the Java application.
--
-- Important rules:
--   * Bind variables use :name notation for readability.
--   * Java performs the primary hash comparison and scenario selection.
--   * State-changing scenarios execute inside one JDBC transaction.
--   * ACTIVE is locked before PENDING whenever both can participate in a change.
--   * ARCHIVAL_ID and SMS_SCHEDULE_ID are identity columns. Never supply them.
--   * All current timestamps are generated explicitly in UTC.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- COMMON LOOKUPS
-- ----------------------------------------------------------------------------

-- Read the currently trusted hash for a customer.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = :custId;

-- Read the current pending hash and its 48-hour cooling boundary.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       COOLING_START_TIME,
       COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId;

-- Lock ACTIVE before a state-changing scenario.
-- Using the same lock order everywhere reduces deadlock risk.
SELECT CUST_ID,
       MOBILE_NUMBER,
       PASSKEY_HASH,
       UPDATED_TIME
FROM ACTIVE_PASSKEY
WHERE CUST_ID = :custId
FOR UPDATE;

-- Lock PENDING only after ACTIVE has been locked.
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
-- Java returns authentication failure, shows the existing ETB menu,
-- does not start cooling, does not schedule SMS, and does not report PRM.

-- ----------------------------------------------------------------------------
-- MALFORMED REQUEST
-- ----------------------------------------------------------------------------
-- Validate required fields before database access.
-- Examples: missing CUST_ID, missing mobile number, VERIFIED with null hash,
-- or PASSKEY_HASH length > 150.
-- Return "Unable to serve your request." with no DB/SMS/PRM side effects.

-- ----------------------------------------------------------------------------
-- SCENARIOS 2 AND 3: first verified passkey
-- ----------------------------------------------------------------------------
-- Used only when no ACTIVE row exists for the customer.
-- CUST_ID is the primary key, so concurrent duplicate first-registration inserts
-- are rejected by Oracle. Java should treat ORA-00001 as a concurrency conflict,
-- re-read current state, and re-evaluate the request instead of overwriting data.
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
-- If no PENDING row exists: no DML is required; return success.
-- If a PENDING row exists: execute Scenario 6 because the original trusted
-- ACTIVE hash has been reconfirmed and the pending change is no longer relevant.

-- ----------------------------------------------------------------------------
-- COMMON: create a new pending verification cycle
-- Used by Scenarios 5, 8 and 10.
-- ----------------------------------------------------------------------------
-- Generate the current UTC timestamp once inside this SQL statement so the
-- cooling start and end are based on exactly the same instant.
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

-- Create all four SMS records from the exact COOLING_START_TIME persisted above.
-- Identity column SMS_SCHEDULE_ID is intentionally omitted from INSERT.
-- Sequence mapping:
--   1 = immediate
--   2 = +15 hours
--   3 = +30 hours
--   4 = +46 hours
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
       END AS SCHEDULED_TIME,
       CASE S.SMS_SEQUENCE
           WHEN 1 THEN P.COOLING_START_TIME
           WHEN 2 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(15, 'HOUR')
           WHEN 3 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(30, 'HOUR')
           WHEN 4 THEN P.COOLING_START_TIME + NUMTODSINTERVAL(46, 'HOUR')
       END AS NEXT_ATTEMPT_TIME,
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

-- Java should verify that exactly four rows were inserted.

-- ----------------------------------------------------------------------------
-- SCENARIO 5: first mismatch
-- ----------------------------------------------------------------------------
-- Preconditions while ACTIVE is locked:
--   * ACTIVE exists.
--   * Incoming hash does not match ACTIVE hash.
--   * No PENDING row exists.
-- Transaction:
--   1. Insert PENDING row.
--   2. Insert exactly four SMS rows.
--   3. Commit.
-- ACTIVE remains unchanged.

-- ----------------------------------------------------------------------------
-- COMMON: archive current PENDING row
-- ----------------------------------------------------------------------------
-- ARCHIVAL_ID is generated by Oracle identity and is intentionally omitted.
-- :archiveReason must be:
--   AR102 = original ACTIVE hash reconfirmed (Scenario 6)
--   AR103 = pending hash replaced during cooling (Scenario 8)
--   AR104 = pending hash replaced after cooling (Scenario 10)
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

-- Java must verify exactly one row was archived before deleting PENDING.

-- ----------------------------------------------------------------------------
-- COMMON: cancel unsent SMS rows for one exact cooling cycle
-- ----------------------------------------------------------------------------
-- :coolingStartTime must be the value read from the locked PENDING row.
-- SENT rows remain for audit. PROCESSING rows are intentionally not cancelled
-- because a provider call may already be in progress; worker/provider idempotency
-- must resolve that race safely.
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

-- Delete current PENDING only after archival/cancellation steps have succeeded.
DELETE FROM PASSKEY_PENDING_VERIFICATION
WHERE CUST_ID = :custId
  AND COOLING_START_TIME = :coolingStartTime;

-- Java should verify exactly one row was deleted.

-- ----------------------------------------------------------------------------
-- SCENARIO 6: original ACTIVE hash used during cooling
-- ----------------------------------------------------------------------------
-- Preconditions:
--   * Incoming hash matches locked ACTIVE hash.
--   * PENDING exists.
-- Transaction:
--   1. Archive PENDING with ARCHIVE_REASON='AR102'.
--   2. Cancel PENDING/QUEUED SMS for the exact cooling cycle.
--   3. Delete PENDING row.
-- ACTIVE remains unchanged; authentication succeeds.

-- ----------------------------------------------------------------------------
-- SCENARIO 7: same PENDING hash during cooling
-- ----------------------------------------------------------------------------
-- Determine whether the cooling period is still active.
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
--   * No DML is performed.
--   * Cooling is not reset.
--   * No additional immediate SMS is created.
--   * Existing 15h/30h/46h schedule continues.
--   * Return authentication failure and report the attempt to PRM.

-- ----------------------------------------------------------------------------
-- SCENARIO 8: a different hash is received during cooling
-- ----------------------------------------------------------------------------
-- Preconditions while rows are locked:
--   * Incoming hash does not match ACTIVE.
--   * Incoming hash does not match PENDING.
--   * Current UTC time < PENDING.COOLING_END_TIME.
-- Transaction:
--   1. Archive old PENDING with AR103.
--   2. Cancel unsent SMS for old COOLING_START_TIME.
--   3. Delete old PENDING.
--   4. Insert new PENDING with a fresh 48-hour cooling period.
--   5. Insert exactly four new SMS rows.
-- ACTIVE remains unchanged.

-- ----------------------------------------------------------------------------
-- SCENARIO 9: matching PENDING hash after cooling
-- ----------------------------------------------------------------------------
-- Preconditions while ACTIVE and PENDING are locked:
--   * Incoming hash does not match ACTIVE.
--   * Incoming hash matches PENDING.
--   * Current UTC time >= PENDING.COOLING_END_TIME.

-- Step 1: archive ACTIVE defensively only when the matching pending hash exists
-- and its cooling period has completed. ARCHIVAL_ID is generated automatically.
INSERT INTO PASSKEY_ARCHIVAL
(
    CUST_ID,
    PASSKEY_HASH,
    SOURCE_TYPE,
    ORIGINAL_UPDATED_TIME,
    ARCHIVE_REASON,
    ARCHIVED_TIME
)
SELECT A.CUST_ID,
       A.PASSKEY_HASH,
       'ACTIVE',
       A.UPDATED_TIME,
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

-- Java must verify exactly one ACTIVE record was archived.

-- Step 2: promote the matching PENDING hash into the stable ACTIVE row.
UPDATE ACTIVE_PASSKEY A
SET (A.PASSKEY_HASH, A.MOBILE_NUMBER, A.UPDATED_TIME) =
    (
        SELECT P.PASSKEY_HASH,
               P.MOBILE_NUMBER,
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

-- Java must verify exactly one ACTIVE row was updated.
-- Step 3: cancel any remaining PENDING/QUEUED SMS for the old cooling cycle.
-- Step 4: delete the PENDING row using CUST_ID + original COOLING_START_TIME.
-- Do NOT archive the pending hash: it is now the current ACTIVE hash.
-- Commit only after all four steps succeed.

-- ----------------------------------------------------------------------------
-- SCENARIO 10: different hash received after cooling completed
-- ----------------------------------------------------------------------------
-- Preconditions while rows are locked:
--   * Incoming hash does not match ACTIVE.
--   * Incoming hash does not match PENDING.
--   * Current UTC time >= PENDING.COOLING_END_TIME.
-- Transaction:
--   1. Archive old PENDING with AR104.
--   2. Cancel unsent SMS for old COOLING_START_TIME.
--   3. Delete old PENDING.
--   4. Insert new PENDING with a fresh 48-hour cooling period.
--   5. Insert exactly four fresh SMS rows.
-- Existing ACTIVE remains unchanged.

-- ----------------------------------------------------------------------------
-- TRANSACTION SAFETY SUMMARY
-- ----------------------------------------------------------------------------
-- Scenario 5  : lock ACTIVE -> confirm no PENDING -> insert PENDING + 4 SMS.
-- Scenario 6  : lock ACTIVE -> lock PENDING -> archive/cancel/delete PENDING.
-- Scenario 7  : read-only.
-- Scenario 8  : lock ACTIVE -> lock PENDING -> archive/cancel/delete old PENDING
--               -> insert new PENDING + 4 SMS.
-- Scenario 9  : lock ACTIVE -> lock PENDING -> archive ACTIVE -> promote PENDING
--               -> cancel remaining SMS -> delete PENDING.
-- Scenario 10 : lock ACTIVE -> lock PENDING -> archive/cancel/delete old PENDING
--               -> insert new PENDING + 4 SMS.
-- Any failure in a state-changing flow must cause JDBC rollback.
