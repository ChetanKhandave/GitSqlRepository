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

They are technical surrogate keys with no business meaning. Java must not generate or provide these values.

## Archive reason codes

| Code | Source | Meaning |
| --- | --- | --- |
| `AR101` | ACTIVE | Previous ACTIVE hash replaced after successful completion of the 48-hour cooling period. |
| `AR102` | PENDING_VERIFICATION | PENDING hash archived because the customer reconfirmed the original ACTIVE hash. |
| `AR103` | PENDING_VERIFICATION | PENDING hash replaced by another different hash while cooling was still active. |
| `AR104` | PENDING_VERIFICATION | PENDING hash replaced by another different hash after the previous cooling period completed. |

The DDL enforces the valid `SOURCE_TYPE + ARCHIVE_REASON` combinations.

## Time handling

All schema timestamps use `TIMESTAMP(6) WITH TIME ZONE`. DML, JDBC and scheduler queries explicitly use UTC with `SYSTIMESTAMP AT TIME ZONE 'UTC'`.

When a new PENDING record is created, one UTC timestamp is selected and reused for both `COOLING_START_TIME` and `COOLING_END_TIME = start + 48 hours`. SMS due times are derived from the stored cooling start.

## JDBC query file

`passkey/jdbc/05_jdbc_queries.sql` contains the SQL intended to be copied into Java/JDBC repository/DAO classes.

The JDBC file uses positional `?` placeholders rather than named bind variables and documents, for every statement:

- exact PreparedStatement parameter order;
- expected query/update row count;
- whether the query is read-only or part of a transaction;
- which business scenario uses it;
- lock ordering requirements.

For state-changing scenarios Java should use:

```java
connection.setAutoCommit(false);
```

and call `commit()` only after every mandatory statement returns the expected result. Any SQL error or unexpected mandatory row count should result in `rollback()`.

### JDBC transaction summary

- Scenarios 2/3: read ACTIVE, then insert first ACTIVE if absent.
- Scenario 5: lock ACTIVE, confirm no PENDING, insert PENDING, insert four SMS rows.
- Scenario 6: lock ACTIVE/PENDING, archive PENDING as `AR102`, cancel unsent SMS, delete PENDING.
- Scenario 7: read-only; no DML while same pending hash is retried within cooling.
- Scenario 8: archive old PENDING as `AR103`, cancel/delete old cycle, create new PENDING and four SMS rows.
- Scenario 9: archive ACTIVE as `AR101`, promote matching PENDING only after cooling, cancel remaining SMS, delete PENDING.
- Scenario 10: archive old PENDING as `AR104`, cancel/delete old cycle, create a fresh 48-hour cycle.

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

The schema includes a matching function-based index. `FOR UPDATE SKIP LOCKED` allows multiple scheduler instances to scan without claiming the same row.

## Execution order

1. Run `passkey/ddl/01_passkey_schema.sql`.
2. Use `passkey/jdbc/05_jdbc_queries.sql` for Java/JDBC implementation.
3. Use `passkey/dml/02_passkey_scenario_queries.sql` as the named-bind/reference version of the business SQL.
4. Use `passkey/scheduler/03_sms_scheduler_queries.sql` for the database scanner and Java `DelayQueue` worker.
5. Use `passkey/dml/04_audit_queries.sql` for support and operational monitoring.
