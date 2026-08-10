-- ============================================================================
-- Oracle 19c SQL used by the Java database scanner and DelayQueue workers.
-- Database time columns are plain TIMESTAMP(6).
-- No UTC conversion or time-zone conversion is performed.
-- LOCALTIMESTAMP is used for all database-generated current timestamps.
-- ============================================================================

-- 1. Scan/claim SMS rows due within a configurable look-ahead window.
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
      <= LOCALTIMESTAMP
         + NUMTODSINTERVAL(:lookAheadMinutes, 'MINUTE')
ORDER BY NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME)
FOR UPDATE SKIP LOCKED;

-- 2. Mark a claimed SMS row as QUEUED.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'QUEUED',
    QUEUED_TIME = LOCALTIMESTAMP,
    LOCKED_BY = :schedulerInstanceId,
    LOCKED_TIME = LOCALTIMESTAMP,
    UPDATED_TIME = LOCALTIMESTAMP
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PENDING';

-- 3. Revalidate that the corresponding pending cooling cycle still exists.
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

-- 4. Atomically transition QUEUED -> PROCESSING.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PROCESSING',
    PROCESSING_START_TIME = LOCALTIMESTAMP,
    ATTEMPT_COUNT = ATTEMPT_COUNT + 1,
    UPDATED_TIME = LOCALTIMESTAMP
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'QUEUED';

-- 5. Mark successful SMS delivery.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'SENT',
    SENT_TIME = LOCALTIMESTAMP,
    NEXT_ATTEMPT_TIME = NULL,
    LAST_ERROR_MESSAGE = NULL,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = LOCALTIMESTAMP
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PROCESSING';

-- 6. Retryable provider/technical failure.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PENDING',
    NEXT_ATTEMPT_TIME =
        LOCALTIMESTAMP
        + NUMTODSINTERVAL(:retryDelayMinutes, 'MINUTE'),
    LAST_ERROR_MESSAGE = :maskedErrorMessage,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = LOCALTIMESTAMP
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PROCESSING';

-- 7. Permanent failure after configured maximum retry count.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'FAILED',
    NEXT_ATTEMPT_TIME = NULL,
    LAST_ERROR_MESSAGE = :maskedErrorMessage,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = LOCALTIMESTAMP
WHERE SMS_SCHEDULE_ID = :smsScheduleId
  AND SMS_STATUS = 'PROCESSING';

-- 8. Recover QUEUED rows whose scheduler lease expired.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PENDING',
    QUEUED_TIME = NULL,
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = LOCALTIMESTAMP
WHERE SMS_STATUS = 'QUEUED'
  AND LOCKED_TIME <
      LOCALTIMESTAMP
      - NUMTODSINTERVAL(:leaseMinutes, 'MINUTE');

-- 9. Recover PROCESSING rows whose processing lease expired.
UPDATE PASSKEY_SMS_SCHEDULE
SET SMS_STATUS = 'PENDING',
    PROCESSING_START_TIME = NULL,
    NEXT_ATTEMPT_TIME =
        LOCALTIMESTAMP
        + NUMTODSINTERVAL(:retryDelayMinutes, 'MINUTE'),
    LAST_ERROR_MESSAGE = 'Recovered after processing lease expiration',
    LOCKED_BY = NULL,
    LOCKED_TIME = NULL,
    UPDATED_TIME = LOCALTIMESTAMP
WHERE SMS_STATUS = 'PROCESSING'
  AND PROCESSING_START_TIME <
      LOCALTIMESTAMP
      - NUMTODSINTERVAL(:leaseMinutes, 'MINUTE');
