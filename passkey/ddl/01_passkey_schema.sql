-- ============================================================================
-- Oracle 19c schema for passkey verification and scheduled SMS delivery.
--
-- Design principles:
--   1. ACTIVE_PASSKEY stores only the currently trusted passkey.
--   2. PASSKEY_PENDING_VERIFICATION stores only the current changed passkey
--      while the 48-hour cooling period applies.
--   3. PASSKEY_ARCHIVAL stores immutable history of replaced/cancelled hashes.
--   4. PASSKEY_SMS_SCHEDULE stores SMS timing/delivery state independently.
--   5. ARCHIVAL_ID and SMS_SCHEDULE_ID are technical surrogate keys generated
--      by Oracle identity columns; Java never supplies these values.
--   6. All timestamps use TIMESTAMP WITH TIME ZONE and DML uses UTC explicitly.
-- ============================================================================

-- ============================================================================
-- ACTIVE_PASSKEY
-- Stores exactly one currently trusted passkey hash for each customer.
-- ============================================================================
CREATE TABLE ACTIVE_PASSKEY
(
    -- Unique customer identifier. Primary key guarantees one active row/customer.
    CUST_ID         VARCHAR2(20 CHAR) NOT NULL,

    -- Registered mobile number associated with the active passkey/customer.
    MOBILE_NUMBER   VARCHAR2(20 CHAR) NOT NULL,

    -- Current trusted passkey hash received from frontend.
    PASSKEY_HASH    VARCHAR2(150 CHAR) NOT NULL,

    -- UTC time at which the active row was inserted or its hash/mobile was updated.
    UPDATED_TIME    TIMESTAMP(6) WITH TIME ZONE
                        DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_ACTIVE_PASSKEY
        PRIMARY KEY (CUST_ID)
);

-- ============================================================================
-- PASSKEY_PENDING_VERIFICATION
-- Stores at most one changed passkey hash per customer while cooling applies.
-- ============================================================================
CREATE TABLE PASSKEY_PENDING_VERIFICATION
(
    -- Customer whose new hash is waiting for verification/cooling completion.
    CUST_ID             VARCHAR2(20 CHAR) NOT NULL,

    -- New hash that did not match the customer's current ACTIVE hash.
    PASSKEY_HASH        VARCHAR2(150 CHAR) NOT NULL,

    -- Mobile number to which cooling-period SMS notifications are sent.
    MOBILE_NUMBER       VARCHAR2(20 CHAR) NOT NULL,

    -- Exact UTC time at which the current 48-hour cooling period started.
    COOLING_START_TIME  TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    -- Exact UTC time when the current cooling period completes.
    COOLING_END_TIME    TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    -- One PENDING row per customer is the business invariant.
    CONSTRAINT PK_PENDING_VERIFICATION
        PRIMARY KEY (CUST_ID),

    -- Prevent an invalid or zero-length cooling window.
    CONSTRAINT CK_PENDING_COOLING_TIME
        CHECK (COOLING_END_TIME > COOLING_START_TIME)
);

-- ============================================================================
-- PASSKEY_ARCHIVAL
-- Immutable history of ACTIVE or PENDING hashes that are no longer current.
--
-- ARCHIVE_REASON code mapping:
--   AR101 = Previous ACTIVE hash replaced after successful 48-hour cooling.
--   AR102 = PENDING hash archived because original ACTIVE hash was reconfirmed.
--   AR103 = PENDING hash replaced by another hash during cooling.
--   AR104 = PENDING hash replaced by another hash after cooling completed.
-- ============================================================================
CREATE TABLE PASSKEY_ARCHIVAL
(
    -- Technical surrogate key generated only by Oracle.
    -- GENERATED ALWAYS prevents Java/manual INSERT statements from supplying it.
    ARCHIVAL_ID                 NUMBER
                                GENERATED ALWAYS AS IDENTITY
                                (START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE)
                                NOT NULL,

    -- Customer to whom the archived hash belonged.
    CUST_ID                     VARCHAR2(20 CHAR) NOT NULL,

    -- Hash value removed from ACTIVE or PENDING state.
    PASSKEY_HASH                VARCHAR2(150 CHAR) NOT NULL,

    -- Origin of the archived hash.
    SOURCE_TYPE                 VARCHAR2(30 CHAR) NOT NULL,

    -- Populated for SOURCE_TYPE='ACTIVE' from ACTIVE_PASSKEY.UPDATED_TIME.
    -- NULL when the archived source was PENDING_VERIFICATION.
    ORIGINAL_UPDATED_TIME       TIMESTAMP(6) WITH TIME ZONE,

    -- Populated for a PENDING source; NULL for an ACTIVE source.
    ORIGINAL_COOLING_START_TIME TIMESTAMP(6) WITH TIME ZONE,

    -- Populated for a PENDING source; NULL for an ACTIVE source.
    ORIGINAL_COOLING_END_TIME   TIMESTAMP(6) WITH TIME ZONE,

    -- Stable business/audit code rather than free-form reason text.
    ARCHIVE_REASON              VARCHAR2(10 CHAR) NOT NULL,

    -- UTC time at which this historical record was inserted.
    ARCHIVED_TIME               TIMESTAMP(6) WITH TIME ZONE
                                    DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_PASSKEY_ARCHIVAL
        PRIMARY KEY (ARCHIVAL_ID),

    CONSTRAINT CK_ARCHIVAL_SOURCE_TYPE
        CHECK (SOURCE_TYPE IN ('ACTIVE', 'PENDING_VERIFICATION')),

    CONSTRAINT CK_PASSKEY_ARCHIVE_REASON
        CHECK (ARCHIVE_REASON IN ('AR101', 'AR102', 'AR103', 'AR104')),

    -- Keep SOURCE_TYPE and ARCHIVE_REASON semantically consistent.
    -- AR101 archives an ACTIVE record; AR102/AR103/AR104 archive PENDING records.
    CONSTRAINT CK_ARCHIVAL_REASON_SOURCE
        CHECK
        (
            (ARCHIVE_REASON = 'AR101' AND SOURCE_TYPE = 'ACTIVE')
            OR
            (ARCHIVE_REASON IN ('AR102', 'AR103', 'AR104')
             AND SOURCE_TYPE = 'PENDING_VERIFICATION')
        )
);

-- ============================================================================
-- PASSKEY_SMS_SCHEDULE
-- One row represents one SMS. Four rows are created for each mismatch cycle:
--   SMS_SEQUENCE=1 -> immediately
--   SMS_SEQUENCE=2 -> cooling start + 15 hours
--   SMS_SEQUENCE=3 -> cooling start + 30 hours
--   SMS_SEQUENCE=4 -> cooling start + 46 hours
--
-- The simplified PENDING table has no synthetic cycle ID. Therefore
-- CUST_ID + COOLING_START_TIME identify one cooling/SMS cycle.
-- ============================================================================
CREATE TABLE PASSKEY_SMS_SCHEDULE
(
    -- Technical surrogate key generated only by Oracle.
    SMS_SCHEDULE_ID         NUMBER
                            GENERATED ALWAYS AS IDENTITY
                            (START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE)
                            NOT NULL,

    -- Customer for whom this SMS is scheduled.
    CUST_ID                 VARCHAR2(20 CHAR) NOT NULL,

    -- Mobile-number snapshot for this cooling cycle.
    MOBILE_NUMBER           VARCHAR2(20 CHAR) NOT NULL,

    -- Snapshot of the PENDING cooling start; forms the logical cycle identifier.
    COOLING_START_TIME      TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    -- 1=immediate, 2=15h, 3=30h, 4=46h.
    SMS_SEQUENCE            NUMBER(1) NOT NULL,

    -- Business time at which this SMS becomes due.
    SCHEDULED_TIME          TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    -- Populated only when a retry should occur later than SCHEDULED_TIME.
    NEXT_ATTEMPT_TIME       TIMESTAMP(6) WITH TIME ZONE,

    -- Current scheduler/delivery state.
    SMS_STATUS              VARCHAR2(20 CHAR) DEFAULT 'PENDING' NOT NULL,

    -- Time the scheduler claimed the row for a DelayQueue instance.
    QUEUED_TIME             TIMESTAMP(6) WITH TIME ZONE,

    -- Time a worker changed QUEUED -> PROCESSING before provider invocation.
    PROCESSING_START_TIME   TIMESTAMP(6) WITH TIME ZONE,

    -- Time successful provider delivery was persisted.
    SENT_TIME               TIMESTAMP(6) WITH TIME ZONE,

    -- Time an unsent SMS was cancelled because the passkey state changed.
    CANCELLED_TIME          TIMESTAMP(6) WITH TIME ZONE,

    -- Operational cancellation reason; separate from archival ARxxx codes.
    CANCEL_REASON           VARCHAR2(60 CHAR),

    -- Number of actual provider-processing attempts.
    ATTEMPT_COUNT           NUMBER DEFAULT 0 NOT NULL,

    -- Masked/truncated technical/provider error. Must not contain sensitive data.
    LAST_ERROR_MESSAGE      VARCHAR2(1000 CHAR),

    -- Scheduler/JVM instance holding the temporary lease.
    LOCKED_BY               VARCHAR2(100 CHAR),

    -- UTC time the temporary scheduler lease was acquired.
    LOCKED_TIME             TIMESTAMP(6) WITH TIME ZONE,

    -- Audit timestamp for row creation.
    CREATED_TIME            TIMESTAMP(6) WITH TIME ZONE
                                DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    -- Audit timestamp for latest row update.
    UPDATED_TIME            TIMESTAMP(6) WITH TIME ZONE
                                DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_PASSKEY_SMS_SCHEDULE
        PRIMARY KEY (SMS_SCHEDULE_ID),

    -- Prevent duplicate 0h/15h/30h/46h rows within the same cooling cycle.
    CONSTRAINT UK_SMS_CYCLE_SEQUENCE
        UNIQUE (CUST_ID, COOLING_START_TIME, SMS_SEQUENCE),

    CONSTRAINT CK_SMS_SEQUENCE
        CHECK (SMS_SEQUENCE IN (1, 2, 3, 4)),

    CONSTRAINT CK_SMS_STATUS
        CHECK
        (
            SMS_STATUS IN
            ('PENDING', 'QUEUED', 'PROCESSING', 'SENT', 'CANCELLED', 'FAILED')
        ),

    CONSTRAINT CK_SMS_ATTEMPT_COUNT
        CHECK (ATTEMPT_COUNT >= 0)
);

-- ============================================================================
-- INDEXES
-- Primary-key and unique constraints already create indexes for:
--   ACTIVE_PASSKEY(CUST_ID)
--   PASSKEY_PENDING_VERIFICATION(CUST_ID)
--   PASSKEY_ARCHIVAL(ARCHIVAL_ID)
--   PASSKEY_SMS_SCHEDULE(SMS_SCHEDULE_ID)
--   PASSKEY_SMS_SCHEDULE(CUST_ID, COOLING_START_TIME, SMS_SEQUENCE)
-- The indexes below support additional access patterns only.
-- ============================================================================

-- Efficiently finds all customers whose cooling period has completed.
CREATE INDEX IDX_PENDING_COOLING_END
    ON PASSKEY_PENDING_VERIFICATION (COOLING_END_TIME);

-- Customer archive-history lookup ordered/filterable by archive time.
CREATE INDEX IDX_ARCHIVAL_CUSTOMER_TIME
    ON PASSKEY_ARCHIVAL (CUST_ID, ARCHIVED_TIME);

-- Scheduler scans use exactly NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME), so a
-- function-based index supports both original schedules and retries efficiently.
CREATE INDEX IDX_SMS_STATUS_DUE_TIME
    ON PASSKEY_SMS_SCHEDULE
       (SMS_STATUS, NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME));

-- Supports cancellation/revalidation for one customer's exact cooling cycle.
CREATE INDEX IDX_SMS_CUSTOMER_CYCLE_STATUS
    ON PASSKEY_SMS_SCHEDULE (CUST_ID, COOLING_START_TIME, SMS_STATUS);

-- Supports customer SMS history queries.
CREATE INDEX IDX_SMS_CUSTOMER_CREATED_TIME
    ON PASSKEY_SMS_SCHEDULE (CUST_ID, CREATED_TIME);
