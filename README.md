# GitSqlRepository

Oracle 19c SQL scripts for passkey verification, a 48-hour cooling period, archival, and scheduled SMS delivery.

## Structure

```text
passkey/
├── ddl/
│   └── 01_passkey_schema.sql
├── dml/
│   ├── 02_passkey_scenario_queries.sql
│   └── 04_audit_queries.sql
└── scheduler/
    └── 03_sms_scheduler_queries.sql
```

## Business model

- `ACTIVE_PASSKEY`: one currently trusted passkey per customer.
- `PASSKEY_PENDING_VERIFICATION`: at most one changed hash per customer during/after the current 48-hour cooling period.
- `PASSKEY_ARCHIVAL`: immutable history of active or pending hashes that are no longer current.
- `PASSKEY_SMS_SCHEDULE`: independent SMS schedule and delivery history. Four rows are created per cooling cycle: immediately, +15 hours, +30 hours and +46 hours.

The simplified passkey tables intentionally do not store request IDs, version numbers, activation timestamps or a synthetic verification-cycle ID. SMS cycles are identified by `CUST_ID + COOLING_START_TIME`.

## Identity columns

`PASSKEY_ARCHIVAL.ARCHIVAL_ID` and `PASSKEY_SMS_SCHEDULE.SMS_SCHEDULE_ID` are Oracle 19c identity columns:

```sql
GENERATED ALWAYS AS IDENTITY
(START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE)
```

They are technical surrogate keys with no business meaning. Java must not generate or provide these values. The previous explicit archive/SMS sequences are therefore no longer required.

## Archive reason codes

| Code | Source | Meaning |
| --- | --- | --- |
| `AR101` | ACTIVE | Previous ACTIVE hash replaced after successful completion of the 48-hour cooling period. |
| `AR102` | PENDING_VERIFICATION | PENDING hash archived because the customer reconfirmed the original ACTIVE hash. |
| `AR103` | PENDING_VERIFICATION | PENDING hash replaced by another different hash while cooling was still active. |
| `AR104` | PENDING_VERIFICATION | PENDING hash replaced by another different hash after the previous cooling period completed. |

The DDL enforces the valid `SOURCE_TYPE + ARCHIVE_REASON` combinations with a check constraint.

## Time handling

All schema timestamps use `TIMESTAMP(6) WITH TIME ZONE`. DML and scheduler queries explicitly use UTC with `SYSTIMESTAMP AT TIME ZONE 'UTC'` so cooling and SMS intervals are based on one consistent time standard.

When a new PENDING record is created, one UTC timestamp is selected and reused for both `COOLING_START_TIME` and `COOLING_END_TIME = start + 48 hours`. SMS due times are derived from the stored cooling start rather than independently calling the clock.

## Transaction and concurrency rules

- Lock `ACTIVE_PASSKEY` before `PASSKEY_PENDING_VERIFICATION` whenever both records are involved in a state change.
- Scenario 5 inserts PENDING plus four SMS rows atomically.
- Scenario 6 archives/cancels/deletes PENDING atomically.
- Scenario 8 archives the old pending state, cancels its unsent SMS, creates a new pending state, and creates four new SMS rows atomically.
- Scenario 9 archives ACTIVE and promotes PENDING only when SQL also confirms the incoming hash matches PENDING and cooling has completed.
- Scenario 10 archives the old pending state and starts a fresh cooling/SMS cycle atomically.
- Any failed state transition must be rolled back by JDBC.
- First-time concurrent inserts are protected by `ACTIVE_PASSKEY(CUST_ID)` primary-key uniqueness; Java should re-read state if an insert loses that race.

## Scheduler design

The database remains the durable source of truth. Java `DelayQueue` is only an in-memory timing mechanism.

The scheduler scan uses:

```sql
NVL(NEXT_ATTEMPT_TIME, SCHEDULED_TIME)
```

The schema includes a matching function-based index so both original scheduled sends and retry sends can be found efficiently. `FOR UPDATE SKIP LOCKED` allows multiple scheduler instances to scan without claiming the same row.

## Execution order

1. Run `passkey/ddl/01_passkey_schema.sql`.
2. Implement the Java transaction flows documented in `passkey/dml/02_passkey_scenario_queries.sql`.
3. Use `passkey/scheduler/03_sms_scheduler_queries.sql` for the database scanner and Java `DelayQueue` worker.
4. Use `passkey/dml/04_audit_queries.sql` for support and operational monitoring.

Bind variables use `:name` notation for readability and should be converted to JDBC placeholders or named parameters by the application.
