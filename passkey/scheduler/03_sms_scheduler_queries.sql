-- ============================================================================
-- Oracle 19c SQL used by the Java database scanner and DelayQueue workers.
-- The database is the persistent source of truth; DelayQueue is only an
-- in-memory timer and may be lost when the JVM restarts.
-- All time comparisons are performed against UTC.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Scan/claim SMS rows due within a configurable look-ahead window.
-- FOR UPDATE SKIP LOCKED allows multiple scheduler instances to scan safely.
-- ----------------------------------------------------------------------------
SELECT SMS_SCHEDULE_ID,
       CUST_ID,
       MOBILE_NUMBER,
       COOLING_START_TIME,
       SMS_SEQUENCE,
       SCHEDULED_TIME,
       NEXT_ATTEMPT_TIME,
       ATTEMPT_COUNT
FROM PASSKEY_SMS_SCHEDULE
WHERE SMS_STATUS = 'PENDING'
  AND NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME)
      <= (SYSTIMESTAMP AT TIME ZONE 'UTC')
         + NUMTODSINTERVAL(:lookAheadMinutes, 'MINUTE')
ORDER BY NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME)
FOR UPDATE SKIP LOCKED;

-- ----------------------------------------------------------------------------
-- 2. Mark a claimed SMS row as QUEUED.
-- Java should add the item to DelayQueue only when exactly one row is updated.
-- ----------------------------------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'QUEUED',
    QUEUED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC',
    LOCKED_BY = :schedulerInstanceId,
    LOCKED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC',
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PENDING';

-- ----------------------------------------------------------------------------
-- 3. Revalidate that the corresponding pending cooling cycle still exists.
-- This prevents sending an SMS after active hash reconfirmation/replacement.
-- ----------------------------------------------------------------------------
SELECT S.SMS_STATUS,
       S.SCHEDULED_TIME,
       S.NEXT_ATTEMPT_TIME,
       CASE
           WHEN P.CUST_ID IS NOT NULL THEN 'Y'
           ELSE 'N'
       END AS PENDING_CYCLE_ACTIVE
FROM PASSKEY_SMS_SCHEDULE S
LEFT JOIN PASSKEY_PENDING_VERIFICATION P
  ON P.CUST_ID = S.CUST_ID
 AND P.COOLING_START_TIME = S.COOLING_START_TIME
WHERE S.SMS_SCHEDULE_ID = :smsScheduleId;

-- Send only when SMS_STATUS='QUEUED' and PENDING_CYCLE_ACTIVE='Y'.

-- ----------------------------------------------------------------------------
-- 4. Atomically transition QUEUED -> PROCESSING.
-- Send SMS only if this update affects exactly one row.
-- ----------------------------------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PROCESSING',
    PROCESSING_START_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC',
    ATTEMPT_COUNT = ATTEMPT_COUNT + 1,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'QUEUED';

-- ----------------------------------------------------------------------------
-- 5. Mark successful SMS delivery.
-- ----------------------------------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'SENT',
    SENT_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC',
    NEXT_ATTEMPT_TIME = NULL,
    LAST_ERROR_MESSAGE = NULL,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PROCESSING';

-- ----------------------------------------------------------------------------
-- 6. Retryable provider/technical failure.
-- :retryDelayMinutes should come from application configuration.
-- LAST_ERROR_MESSAGE must be masked/truncated and contain no sensitive data.
-- ----------------------------------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PENDING',
    NEXT_ATTEMPT_TIME =
        (SYSTIMESTAMP AT TIME ZONE 'UTC')
        + NUMTODSINTERVAL(:retryDelayMinutes, 'MINUTE'),
    LAST_ERROR_MESSAGE = :maskedErrorMessage,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PROCESSING';

-- ----------------------------------------------------------------------------
-- 7. Permanent failure after the configured maximum retry count.
-- ----------------------------------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'FAILED',
    NEXT_ATTEMPT_TIME = NULL,
    LAST_ERROR_MESSAGE = :maskedErrorMessage,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PROCESSING';

-- ----------------------------------------------------------------------------
-- 8. Recover QUEUED rows stranded because a scheduler JVM terminated before
-- the DelayQueue item could be processed. The lease duration is configurable.
-- ----------------------------------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PENDING',
    QUEUED_TIME = NULL,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE SMS_STATUS = 'QUEUED'
  AND LOCKED_TIME <
      (SYSTIMESTAMP AT TIME ZONE 'UTC')
      - NUMTODSINTERVAL(:leaseMinutes, 'MINUTE');

-- ----------------------------------------------------------------------------
-- 9. Recover PROCESSING rows whose processing lease expired.
-- Provider-side idempotency is recommended because the provider may have
-- accepted the SMS even if the application did not persist the SENT status.
-- ----------------------------------------------------------------------------
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PENDING',
    PROCESSING_START_TIME = NULL,
    NEXT_ATTEMPT_TIME =
        (SYSTIMESTAMP AT TIME ZONE 'UTC')
        + NUMTODSINTERVAL(:retryDelayMinutes, 'MINUTE'),
    LAST_ERROR_MESSAGE = 'Recovered after processing lease expiration',
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = SYSTIMESTAMP AT TIME ZONE 'UTC'
WHERE SMS_STATUS = 'PROCESSING'
  AND PROCESSING_START_TIME <
      (SYSTIMESTAMP AT TIME ZONE 'UTC')
      - NUMTODSINTERVAL(:leaseMinutes, 'MINUTE');
