-- ============================================================================
-- Oracle 19c schema for passkey verification and scheduled SMS delivery.
--
-- Design principles:
--   1. ACTIVE_PASSKEY stores only the currently trusted passkey.
--   2. PASSKEY_PENDING_VERIFICATION stores only the current changed passkey
--      while the 48-hour cooling period is active or awaiting re-attempt.
--   3. PASSKEY_ARCHIVAL stores immutable history of replaced/cancelled hashes.
--   4. PASSKEY_SMS_SCHEDULE stores SMS timing/delivery state independently.
--   5. All timestamps use TIMESTAMP WITH TIME ZONE. Application/database
--      deployments should use UTC consistently.
-- ============================================================================

-- Sequence used only to generate the primary key of PASSKEY_ARCHIVAL.
CREATE SEQUENCE SEQ_PASSKEY_ARCHIVAL
    START WITH 1
    INCREMENT BY 1
    CACHE 100
    NOCYCLE;

-- Sequence used only to generate the primary key of PASSKEY_SMS_SCHEDULE.
CREATE SEQUENCE SEQ_PASSKEY_SMS_SCHEDULE
    START WITH 1
    INCREMENT BY 1
    CACHE 100
    NOCYCLE;

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

    -- Time at which this active row was inserted or its hash/mobile was updated.
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

    -- CUST_ID is the primary key because only one pending hash is allowed/customer.
    CONSTRAINT PK_PENDING_VERIFICATION
        PRIMARY KEY (CUST_ID),

    -- Protects against invalid cooling windows.
    CONSTRAINT CK_PENDING_COOLING_TIME
        CHECK (COOLING_END_TIME > COOLING_START_TIME)
);

-- ============================================================================
-- PASSKEY_ARCHIVAL
-- Immutable history of ACTIVE or PENDING hashes that are no longer current.
-- ARCHIVE_REASON stores a short stable reason code rather than long text.
--
-- Reason code mapping:
--   AR101 = Previous ACTIVE hash replaced after successful 48-hour cooling.
--   AR102 = PENDING hash archived because original ACTIVE hash was reconfirmed.
--   AR103 = PENDING hash replaced by another hash during cooling.
--   AR104 = PENDING hash replaced by another hash after cooling completed.
-- ============================================================================
CREATE TABLE PASSKEY_ARCHIVAL
(
    -- Unique archive record identifier.
    ARCHIVAL_ID                 NUMBER NOT NULL,

    -- Customer to whom the archived hash belonged.
    CUST_ID                     VARCHAR2(20 CHAR) NOT NULL,

    -- Hash value that has been removed from ACTIVE or PENDING state.
    PASSKEY_HASH                VARCHAR2(150 CHAR) NOT NULL,

    -- Indicates whether archived hash came from ACTIVE or PENDING table.
    SOURCE_TYPE                 VARCHAR2(30 CHAR) NOT NULL,

    -- For ACTIVE source: original ACTIVE_PASSKEY.UPDATED_TIME.
    -- For PENDING source this value remains NULL.
    ORIGINAL_UPDATED_TIME       TIMESTAMP(6) WITH TIME ZONE,

    -- For PENDING source: original cooling start time. NULL for ACTIVE source.
    ORIGINAL_COOLING_START_TIME TIMESTAMP(6) WITH TIME ZONE,

    -- For PENDING source: original cooling end time. NULL for ACTIVE source.
    ORIGINAL_COOLING_END_TIME   TIMESTAMP(6) WITH TIME ZONE,

    -- Stable archive reason code: AR101, AR102, AR103 or AR104.
    ARCHIVE_REASON              VARCHAR2(10 CHAR) NOT NULL,

    -- UTC time at which the record was copied into archival history.
    ARCHIVED_TIME               TIMESTAMP(6) WITH TIME ZONE
                                    DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_PASSKEY_ARCHIVAL
        PRIMARY KEY (ARCHIVAL_ID),

    CONSTRAINT CK_ARCHIVAL_SOURCE_TYPE
        CHECK (SOURCE_TYPE IN ('ACTIVE', 'PENDING_VERIFICATION')),

    CONSTRAINT CK_PASSKEY_ARCHIVE_REASON
        CHECK (ARCHIVE_REASON IN ('AR101', 'AR102', 'AR103', 'AR104'))
);

-- ============================================================================
-- PASSKEY_SMS_SCHEDULE
-- Stores one row for each SMS. Four rows are created for every mismatch cycle:
--   sequence 1 = immediately
--   sequence 2 = cooling start + 15 hours
--   sequence 3 = cooling start + 30 hours
--   sequence 4 = cooling start + 46 hours
--
-- Because VERIFICATION_CYCLE_ID was intentionally removed from the simplified
-- passkey tables, CUST_ID + COOLING_START_TIME identify the SMS cooling cycle.
-- ============================================================================
CREATE TABLE PASSKEY_SMS_SCHEDULE
(
    -- Unique identifier for each individual scheduled SMS.
    SMS_SCHEDULE_ID         NUMBER NOT NULL,

    -- Customer for whom the SMS is scheduled.
    CUST_ID                 VARCHAR2(20 CHAR) NOT NULL,

    -- Mobile number snapshot used for this SMS cycle.
    MOBILE_NUMBER           VARCHAR2(20 CHAR) NOT NULL,

    -- Snapshot of the cooling start time; identifies the corresponding cycle.
    COOLING_START_TIME      TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    -- 1=immediate, 2=15h, 3=30h, 4=46h.
    SMS_SEQUENCE            NUMBER(1) NOT NULL,

    -- Business scheduled time for this SMS.
    SCHEDULED_TIME          TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    -- Used only when a failed SMS is scheduled for retry.
    NEXT_ATTEMPT_TIME       TIMESTAMP(6) WITH TIME ZONE,

    -- Current delivery state used by database scanner and DelayQueue workers.
    SMS_STATUS              VARCHAR2(20 CHAR) DEFAULT 'PENDING' NOT NULL,

    -- Time scheduler claimed the row and placed/planned it for DelayQueue.
    QUEUED_TIME             TIMESTAMP(6) WITH TIME ZONE,

    -- Time SMS worker started provider processing.
    PROCESSING_START_TIME   TIMESTAMP(6) WITH TIME ZONE,

    -- Successful provider-send timestamp.
    SENT_TIME               TIMESTAMP(6) WITH TIME ZONE,

    -- Time an unsent message was cancelled because pending state changed.
    CANCELLED_TIME          TIMESTAMP(6) WITH TIME ZONE,

    -- Operational cancellation reason. Kept separate from archive reason code.
    CANCEL_REASON           VARCHAR2(60 CHAR),

    -- Number of provider send attempts made for this SMS.
    ATTEMPT_COUNT           NUMBER DEFAULT 0 NOT NULL,

    -- Masked/truncated provider or technical error for support purposes.
    LAST_ERROR_MESSAGE      VARCHAR2(1000 CHAR),

    -- Scheduler/JVM instance currently holding the temporary processing lease.
    LOCKED_BY               VARCHAR2(100 CHAR),

    -- Time the temporary scheduler lease was acquired.
    LOCKED_TIME             TIMESTAMP(6) WITH TIME ZONE,

    -- Audit time for row creation.
    CREATED_TIME            TIMESTAMP(6) WITH TIME ZONE
                                DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    -- Audit time of the most recent SMS row update.
    UPDATED_TIME            TIMESTAMP(6) WITH TIME ZONE
                                DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_PASSKEY_SMS_SCHEDULE
        PRIMARY KEY (SMS_SCHEDULE_ID),

    -- Prevents duplicate SMS sequence rows for the same cooling cycle/customer.
    CONSTRAINT UK_SMS_CYCLE_SEQUENCE
        UNIQUE (CUST_ID, COOLING_START_TIME, SMS_SEQUENCE),

    CONSTRAINT CK_SMS_SEQUENCE
        CHECK (SMS_SEQUENCE IN (1, 2, 3, 4)),

    CONSTRAINT CK_SMS_STATUS
        CHECK (SMS_STATUS IN
               ('PENDING', 'QUEUED', 'PROCESSING', 'SENT', 'CANCELLED', 'FAILED'))
);

-- Supports fast cooling-period checks for a customer.
CREATE INDEX IDX_PENDING_CUSTOMER_COOLING
    ON PASSKEY_PENDING_VERIFICATION (CUST_ID, COOLING_END_TIME);

-- Supports customer archive-history lookup in reverse chronological order.
CREATE INDEX IDX_ARCHIVAL_CUSTOMER_TIME
    ON PASSKEY_ARCHIVAL (CUST_ID, ARCHIVED_TIME);

-- Main scheduler index for scanning pending SMS by scheduled time.
CREATE INDEX IDX_SMS_STATUS_SCHEDULE_TIME
    ON PASSKEY_SMS_SCHEDULE (SMS_STATUS, SCHEDULED_TIME);

-- Supports cancellation and history lookup for one customer/cooling cycle.
CREATE INDEX IDX_SMS_CUSTOMER_CYCLE_STATUS
    ON PASSKEY_SMS_SCHEDULE (CUST_ID, COOLING_START_TIME, SMS_STATUS);

-- Supports customer SMS history queries.
CREATE INDEX IDX_SMS_CUSTOMER_TIME
    ON PASSKEY_SMS_SCHEDULE (CUST_ID, CREATED_TIME);

-- Supports retry scans when NEXT_ATTEMPT_TIME is populated.
CREATE INDEX IDX_SMS_NEXT_ATTEMPT
    ON PASSKEY_SMS_SCHEDULE (SMS_STATUS, NEXT_ATTEMPT_TIME);
