# GitSqlRepository

Oracle 19c SQL scripts for passkey verification, a 48-hour cooling period, archival, scheduled SMS delivery, and JDBC integration.

## Structure

```text
passkey/
├── ddl/
│   └── 01_passkey_schema.sql
├── dml/
│   ├── 02_passkey_scenario_queries.sql
│   └── 04_audit_queries.sql
├── jdbc/
│   └── 05_jdbc_queries.sql
└── scheduler/
    └── 03_sms_scheduler_queries.sql
```

## Business model

- `ACTIVE_PASSKEY`: one currently trusted passkey per customer. It also stores the cooling window through which the current hash became active. Those two fields are `NULL` for a passkey that became active on first registration.
- `PASSKEY_PENDING_VERIFICATION`: at most one changed hash per customer during/after the current 48-hour cooling period.
- `PASSKEY_ARCHIVAL`: immutable history of active or pending hashes that are no longer current. When an ACTIVE hash is archived, its historical activation cooling window is copied too.
- `PASSKEY_SMS_SCHEDULE`: independent SMS schedule and delivery history. Four rows are created per cooling cycle: immediately, +15 hours, +30 hours and +46 hours.

SMS cycles are identified by `CUST_ID + COOLING_START_TIME`.

## Why ACTIVE stores cooling timestamps

When a PENDING hash successfully completes 48 hours and is promoted in Scenario 9, the PENDING row is deleted. `ACTIVE_PASSKEY` therefore retains `COOLING_START_TIME` and `COOLING_END_TIME` so the activation history can later be copied into `PASSKEY_ARCHIVAL`.

## Identity columns

`PASSKEY_ARCHIVAL.ARCHIVAL_ID` and `PASSKEY_SMS_SCHEDULE.SMS_SCHEDULE_ID` use Oracle identity columns:

```sql
GENERATED ALWAYS AS IDENTITY
(START WITH 1 INCREMENT BY 1 CACHE 100 NOCYCLE)
```

Java must not generate or provide these values.

## Archive reason codes

| Code | Source | Meaning |
| --- | --- | --- |
| `AR101` | ACTIVE | Previous ACTIVE hash replaced after successful completion of the 48-hour cooling period. |
| `AR102` | PENDING_VERIFICATION | PENDING hash archived because the customer reconfirmed the original ACTIVE hash. |
| `AR103` | PENDING_VERIFICATION | PENDING hash replaced by another different hash while cooling was still active. |
| `AR104` | PENDING_VERIFICATION | PENDING hash replaced by another different hash after the previous cooling period completed. |

## Time handling

All database date/time columns use plain Oracle `TIMESTAMP(6)` — not `TIMESTAMP WITH TIME ZONE`.

The application/database convention is that every stored timestamp represents **UTC**. Because plain `TIMESTAMP` carries no offset or zone metadata, code must not interpret these values as database-session local time.

Whenever Oracle generates the current time, the SQL uses:

```sql
SYS_EXTRACT_UTC(SYSTIMESTAMP)
```

`SYS_EXTRACT_UTC` converts Oracle's `SYSTIMESTAMP` to UTC and returns a plain `TIMESTAMP`, matching the table column type.

When a PENDING row is created, one UTC timestamp is reused for both cooling start and `start + 48 hours`. SMS due times are derived from the stored cooling start.

For JDBC, bind/read these columns as `java.sql.Timestamp` (or convert to/from `Instant` in the Java layer while preserving the UTC convention).

## JDBC guidance

`passkey/jdbc/05_jdbc_queries.sql` contains positional `?` SQL ready for `PreparedStatement` usage. It documents parameter order and expected row counts.

For state-changing scenarios:

```java
connection.setAutoCommit(false);
```

Commit only after all mandatory statements succeed; otherwise roll back.

Important Scenario 9 behavior:

- archive the old ACTIVE record including its existing cooling timestamps;
- promote PENDING to ACTIVE including `PASSKEY_HASH`, `MOBILE_NUMBER`, `COOLING_START_TIME`, and `COOLING_END_TIME`;
- cancel remaining SMS for the old pending cycle;
- delete the PENDING row.

## Transaction and concurrency rules

- Lock `ACTIVE_PASSKEY` before `PASSKEY_PENDING_VERIFICATION` whenever both records are involved.
- Scenario 5 inserts PENDING plus four SMS rows atomically.
- Scenario 6 archives/cancels/deletes PENDING atomically.
- Scenario 8 archives the old pending state, cancels its SMS, and creates a fresh cycle atomically.
- Scenario 9 archives ACTIVE and promotes PENDING only after hash match and cooling completion are confirmed.
- Scenario 10 archives the old pending state and starts a fresh cycle atomically.
- Any failed transition must be rolled back.

## Scheduler design

The database remains the durable source of truth. Java `DelayQueue` is only an in-memory timing mechanism. Scheduler scans use `FOR UPDATE SKIP LOCKED` and the function-based due-time index.

## Execution order

1. Run `passkey/ddl/01_passkey_schema.sql`.
2. Use `passkey/jdbc/05_jdbc_queries.sql` for Java/JDBC implementation.
3. Use `passkey/dml/02_passkey_scenario_queries.sql` as the named-bind/reference version.
4. Use `passkey/scheduler/03_sms_scheduler_queries.sql` for SMS scanning and DelayQueue workers.
5. Use `passkey/dml/04_audit_queries.sql` for support and operational monitoring.
