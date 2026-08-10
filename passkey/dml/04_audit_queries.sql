-- ============================================================================
-- Support and audit queries for the passkey schema.
-- Avoid exposing full passkey hashes in operational UIs or application logs.
-- All current-time comparisons use UTC.
-- ============================================================================

-- Current ACTIVE and PENDING state for one customer.
-- ACTIVE_COOLING_* is historical provenance for how the current ACTIVE hash was
-- activated. It is NULL for first-registration hashes.
SELECT A.CUST_ID,
       A.MOBILE_NUMBER,
       A.PASSKEY_HASH AS ACTIVE_HASH,
       A.COOLING_START_TIME AS ACTIVE_COOLING_START_TIME,
       A.COOLING_END_TIME AS ACTIVE_COOLING_END_TIME,
       A.UPDATED_TIME AS ACTIVE_UPDATED_TIME,
       P.PASSKEY_HASH AS PENDING_HASH,
       P.COOLING_START_TIME AS PENDING_COOLING_START_TIME,
       P.COOLING_END_TIME AS PENDING_COOLING_END_TIME,
       CASE
           WHEN P.COOLING_END_TIME IS NULL THEN 'NOT_APPLICABLE'
           WHEN (SYSTIMESTAMP AT TIME ZONE 'UTC') < P.COOLING_END_TIME
               THEN 'ACTIVE'
           ELSE 'COMPLETED'
       END AS PENDING_COOLING_STATUS
FROM ACTIVE_PASSKEY A
LEFT JOIN PASSKEY_PENDING_VERIFICATION P
  ON P.CUST_ID = A.CUST_ID
WHERE A.CUST_ID = :custId;

-- Complete archive history. For ACTIVE source, ORIGINAL_COOLING_* describes the
-- cooling window through which that archived hash originally became ACTIVE.
SELECT ARCHIVAL_ID,
       CUST_ID,
       SOURCE_TYPE,
       ORIGINAL_UPDATED_TIME,
       ORIGINAL_COOLING_START_TIME,
       ORIGINAL_COOLING_END_TIME,
       ARCHIVE_REASON,
       ARCHIVED_TIME
FROM PASSKEY_ARCHIVAL
WHERE CUST_ID = :custId
ORDER BY ARCHIVED_TIME DESC;

-- SMS delivery history for one customer, grouped by cooling cycle.
SELECT SMS_SCHEDULE_ID,
       CUST_ID,
       MOBILE_NUMBER,
       COOLING_START_TIME,
       SMS_SEQUENCE,
       SCHEDULED_TIME,
       NEXT_ATTEMPT_TIME,
       SMS_STATUS,
       ATTEMPT_COUNT,
       SENT_TIME,
       CANCELLED_TIME,
       CANCEL_REASON
FROM PASSKEY_SMS_SCHEDULE
WHERE CUST_ID = :custId
ORDER BY COOLING_START_TIME DESC,
         SMS_SEQUENCE;

-- Pending records whose cooling period has completed.
SELECT CUST_ID,
       MOBILE_NUMBER,
       COOLING_START_TIME,
       COOLING_END_TIME
FROM PASSKEY_PENDING_VERIFICATION
WHERE (SYSTIMESTAMP AT TIME ZONE 'UTC') >= COOLING_END_TIME
ORDER BY COOLING_END_TIME;

-- Scheduler backlog summary.
SELECT SMS_STATUS,
       COUNT(*) AS RECORD_COUNT,
       MIN(NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME)) AS EARLIEST_DUE_TIME
FROM PASSKEY_SMS_SCHEDULE
GROUP BY SMS_STATUS
ORDER BY SMS_STATUS;

-- Overdue pending SMS rows.
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
      < (SYSTIMESTAMP AT TIME ZONE 'UTC')
ORDER BY NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME);
