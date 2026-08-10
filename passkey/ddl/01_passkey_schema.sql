-- ============================================================================
-- Oracle 19c schema for passkey verification and scheduled SMS delivery.
--
-- Design principles:
--   1. ACTIVE_PASSKEY stores only the currently trusted passkey.
--   2. ACTIVE_PASSKEY also retains the cooling window through which the current
--      hash became ACTIVE. These values are NULL for first-time registration.
--   3. PASSKEY_PENDING_VERIFICATION stores only the current changed passkey
--      while the 48-hour cooling period applies.
--   4. PASSKEY_ARCHIVAL stores immutable history of replaced/cancelled hashes.
--   5. PASSKEY_SMS_SCHEDULE stores SMS timing/delivery state independently.
--   6. ARCHIVAL_ID and SMS_SCHEDULE_ID are technical surrogate keys generated
--      by Oracle identity columns; Java never supplies these values.
--   7. All timestamps use TIMESTAMP WITH TIME ZONE and DML uses UTC explicitly.
-- ============================================================================

-- ============================================================================
-- ACTIVE_PASSKEY
-- Stores exactly one currently trusted passkey hash for each customer.
-- COOLING_* columns represent the historical activation cooling window for the
-- current ACTIVE hash; they do NOT mean that the customer is currently cooling.
-- ============================================================================
CREATE TABLE ACTIVE_PASSKEY
(
    -- Unique customer identifier. Primary key guarantees one active row/customer.
    CUST_ID             VARCHAR2(20 CHAR) NOT NULL,

    -- Registered mobile number associated with the active passkey/customer.
    MOBILE_NUMBER       VARCHAR2(20 CHAR) NOT NULL,

    -- Current trusted passkey hash received from frontend.
    PASSKEY_HASH        VARCHAR2(150 CHAR) NOT NULL,

    -- Cooling window through which the current ACTIVE hash was promoted.
    -- Both values are NULL when the hash became ACTIVE on first registration.
    COOLING_START_TIME  TIMESTAMP(6) WITH TIME ZONE,
    COOLING_END_TIME    TIMESTAMP(6) WITH TIME ZONE,

    -- UTC time at which the active row was inserted or its active state updated.
    UPDATED_TIME        TIMESTAMP(6) WITH TIME ZONE
                            DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_ACTIVE_PASSKEY
        PRIMARY KEY (CUST_ID),

    -- Either no historical cooling window exists, or both timestamps exist and
    -- form a valid positive interval.
    CONSTRAINT CK_ACTIVE_COOLING_TIME
        CHECK
        (
            (COOLING_START_TIME IS NULL AND COOLING_END_TIME IS NULL)
            OR
            (COOLING_START_TIME IS NOT NULL
             AND COOLING_END_TIME IS NOT NULL
             AND COOLING_END_TIME > COOLING_START_TIME)
        )
);

-- ============================================================================
-- PASSKEY_PENDING_VERIFICATION
-- Stores at most one changed passkey hash per customer while cooling applies.
-- ============================================================================
CREATE TABLE PASSKEY_PENDING_VERIFICATION
(
    CUST_ID             VARCHAR2(20 CHAR) NOT NULL,
    PASSKEY_HASH        VARCHAR2(150 CHAR) NOT NULL,
    MOBILE_NUMBER       VARCHAR2(20 CHAR) NOT NULL,
    COOLING_START_TIME  TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    COOLING_END_TIME    TIMESTAMP(6) WITH TIME ZONE NOT NULL,

    CONSTRAINT PK_PENDING_VERIFICATION
        PRIMARY KEY (CUST_ID),

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
    ARCHIVAL_ID                 NUMBER
                                GENERATED ALWAYS AS IDENTITY
                                (START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE)
                                NOT NULL,

    CUST_ID                     VARCHAR2(20 CHAR) NOT NULL,
    PASSKEY_HASH                VARCHAR2(150 CHAR) NOT NULL,
    SOURCE_TYPE                 VARCHAR2(30 CHAR) NOT NULL,

    -- For ACTIVE source: original ACTIVE_PASSKEY.UPDATED_TIME.
    ORIGINAL_UPDATED_TIME       TIMESTAMP(6) WITH TIME ZONE,

    -- For ACTIVE source: cooling window through which that hash became ACTIVE.
    -- For PENDING source: cooling window of the pending verification attempt.
    -- These values may be NULL only for an ACTIVE hash created on first registration.
    ORIGINAL_COOLING_START_TIME TIMESTAMP(6) WITH TIME ZONE,
    ORIGINAL_COOLING_END_TIME   TIMESTAMP(6) WITH TIME ZONE,

    ARCHIVE_REASON              VARCHAR2(10 CHAR) NOT NULL,

    ARCHIVED_TIME               TIMESTAMP(6) WITH TIME ZONE
                                    DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_PASSKEY_ARCHIVAL
        PRIMARY KEY (ARCHIVAL_ID),

    CONSTRAINT CK_ARCHIVAL_SOURCE_TYPE
        CHECK (SOURCE_TYPE IN ('ACTIVE', 'PENDING_VERIFICATION')),

    CONSTRAINT CK_PASSKEY_ARCHIVE_REASON
        CHECK (ARCHIVE_REASON IN ('AR101', 'AR102', 'AR103', 'AR104')),

    CONSTRAINT CK_ARCHIVAL_REASON_SOURCE
        CHECK
        (
            (ARCHIVE_REASON = 'AR101' AND SOURCE_TYPE = 'ACTIVE')
            OR
            (ARCHIVE_REASON IN ('AR102', 'AR103', 'AR104')
             AND SOURCE_TYPE = 'PENDING_VERIFICATION')
        ),

    -- Cooling timestamps, when present, must be a complete valid pair.
    CONSTRAINT CK_ARCHIVAL_COOLING_TIME
        CHECK
        (
            (ORIGINAL_COOLING_START_TIME IS NULL
             AND ORIGINAL_COOLING_END_TIME IS NULL)
            OR
            (ORIGINAL_COOLING_START_TIME IS NOT NULL
             AND ORIGINAL_COOLING_END_TIME IS NOT NULL
             AND ORIGINAL_COOLING_END_TIME > ORIGINAL_COOLING_START_TIME)
        )
);

-- ============================================================================
-- PASSKEY_SMS_SCHEDULE
-- One row represents one SMS. Four rows are created for each mismatch cycle:
--   SMS_SEQUENCE=1 -> immediately
--   SMS_SEQUENCE=2 -> cooling start + 15 hours
--   SMS_SEQUENCE=3 -> cooling start + 30 hours
--   SMS_SEQUENCE=4 -> cooling start + 46 hours
-- ============================================================================
CREATE TABLE PASSKEY_SMS_SCHEDULE
(
    SMS_SCHEDULE_ID         NUMBER
                            GENERATED ALWAYS AS IDENTITY
                            (START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE)
                            NOT NULL,

    CUST_ID                 VARCHAR2(20 CHAR) NOT NULL,
    MOBILE_NUMBER           VARCHAR2(20 CHAR) NOT NULL,
    COOLING_START_TIME      TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    SMS_SEQUENCE            NUMBER(1) NOT NULL,
    SCHEDULED_TIME          TIMESTAMP(6) WITH TIME ZONE NOT NULL,
    NEXT_ATTEMPT_TIME       TIMESTAMP(6) WITH TIME ZONE,
    SMS_STATUS              VARCHAR2(20 CHAR) DEFAULT 'PENDING' NOT NULL,
    QUEUED_TIME             TIMESTAMP(6) WITH TIME ZONE,
    PROCESSING_START_TIME   TIMESTAMP(6) WITH TIME ZONE,
    SENT_TIME               TIMESTAMP(6) WITH TIME ZONE,
    CANCELLED_TIME          TIMESTAMP(6) WITH TIME ZONE,
    CANCEL_REASON           VARCHAR2(60 CHAR),
    ATTEMPT_COUNT           NUMBER DEFAULT 0 NOT NULL,
    LAST_ERROR_MESSAGE      VARCHAR2(1000 CHAR),
    LOCKED_BY               VARCHAR2(100 CHAR),
    LOCKED_TIME             TIMESTAMP(6) WITH TIME ZONE,
    CREATED_TIME            TIMESTAMP(6) WITH TIME ZONE
                                DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,
    UPDATED_TIME            TIMESTAMP(6) WITH TIME ZONE
                                DEFAULT (SYSTIMESTAMP AT TIME ZONE 'UTC') NOT NULL,

    CONSTRAINT PK_PASSKEY_SMS_SCHEDULE
        PRIMARY KEY (SMS_SCHEDULE_ID),

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

-- Efficiently finds all customers whose cooling period has completed.
CREATE INDEX IDX_PENDING_COOLING_END
    ON PASSKEY_PENDING_VERIFICATION (COOLING_END_TIME);

-- Customer archive-history lookup.
CREATE INDEX IDX_ARCHIVAL_CUSTOMER_TIME
    ON PASSKEY_ARCHIVAL (CUST_ID, ARCHIVED_TIME);

-- Main scheduler/retry scan index.
CREATE INDEX IDX_SMS_STATUS_DUE_TIME
    ON PASSKEY_SMS_SCHEDULE
       (SMS_STATUS, NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME));

-- Cancellation/revalidation for one exact cooling cycle.
CREATE INDEX IDX_SMS_CUSTOMER_CYCLE_STATUS
    ON PASSKEY_SMS_SCHEDULE (CUST_ID, COOLING_START_TIME, SMS_STATUS);

-- Customer SMS history lookup.
CREATE INDEX IDX_SMS_CUSTOMER_CREATED_TIME
    ON PASSKEY_SMS_SCHEDULE (CUST_ID, CREATED_TIME);
