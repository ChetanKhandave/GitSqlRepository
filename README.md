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

The simplified passkey tables intentionally do not store request IDs, version numbers, activation timestamps or verification-cycle IDs. SMS cycles are identified by `CUST_ID + COOLING_START_TIME`.

## Archive reason codes

| Code | Meaning |
| --- | --- |
| `AR101` | Previous ACTIVE hash replaced after successful completion of the 48-hour cooling period. |
| `AR102` | PENDING hash archived because the customer reconfirmed the original ACTIVE hash. |
| `AR103` | PENDING hash replaced by another different hash while cooling was still active. |
| `AR104` | PENDING hash replaced by another different hash after the previous cooling period completed. |

## Time handling

All schema timestamps use `TIMESTAMP(6) WITH TIME ZONE`. DML and scheduler queries explicitly use UTC with `SYSTIMESTAMP AT TIME ZONE 'UTC'` so cooling and SMS intervals are based on one consistent time standard.

## Execution order

1. Run `passkey/ddl/01_passkey_schema.sql`.
2. Implement the Java transaction flows documented in `passkey/dml/02_passkey_scenario_queries.sql`.
3. Use `passkey/scheduler/03_sms_scheduler_queries.sql` for the database scanner and Java `DelayQueue` worker.
4. Use `passkey/dml/04_audit_queries.sql` for support and operational monitoring.

## Transaction rule

Each state transition must be atomic. For example, Scenario 8 must archive the previous pending hash, cancel its unsent SMS rows, remove the old pending row, create the new pending row, and create the new four-message SMS schedule within one database transaction.

Bind variables use `:name` notation for readability and should be converted to JDBC placeholders or named parameters by the Java application.
