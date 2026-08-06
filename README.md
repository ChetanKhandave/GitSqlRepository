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

- `ACTIVE_PASSKEY`: one trusted passkey per customer.
- `PASSKEY_PENDING_VERIFICATION`: at most one changed hash in a 48-hour cooling period.
- `PASSKEY_ARCHIVAL`: immutable history of replaced active and pending hashes.
- `PASSKEY_SMS_SCHEDULE`: four SMS records per verification cycle, scheduled immediately and after 15, 30, and 46 hours.

The Java application performs hash comparison and executes each scenario's related DML in one database transaction. The database remains the source of truth; Java `DelayQueue` is used only for in-memory timing.

## Execution order

1. Run `passkey/ddl/01_passkey_schema.sql`.
2. Implement the Java transaction flows documented in `passkey/dml/02_passkey_scenario_queries.sql`.
3. Use `passkey/scheduler/03_sms_scheduler_queries.sql` for the database scanner and DelayQueue worker.
4. Use `passkey/dml/04_audit_queries.sql` for support and operational monitoring.

Bind variables use `:name` notation for readability and should be converted to JDBC placeholders or named parameters by the application.
