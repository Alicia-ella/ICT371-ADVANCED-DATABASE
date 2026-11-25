# ICT371 Advanced Database: SQL Solutions

Ten questions, one script per question. Each script covers parts (a) to (g): tables and seed data, function, procedure, trigger, view, index with `EXPLAIN`, and a scheduled job.

Written for **PostgreSQL 16** (PL/pgSQL). Scheduled jobs use the **pg_cron** extension.

| File | Question |
|---|---|
| `q01_pharmacy.sql` | Pharmacy Stock and Daily Sales |
| `q02_fee_payments.sql` | University Fee Payments |
| `q03_library_fines.sql` | Library Returns and Overdue Fines |
| `q04_clinic_appointments.sql` | Clinic Appointment Scheduling |
| `q05_hostel_allocation.sql` | Hostel Room Allocation |
| `q06_payroll.sql` | Monthly Payroll Processing |
| `q07_water_billing.sql` | Water Meter Readings and Billing |
| `q08_fleet_maintenance.sql` | Transport Fleet Maintenance |
| `q09_maize_deliveries.sql` | Farmer Cooperative Maize Deliveries |
| `q10_scholarships.sql` | Scholarship Application Assessment |

## How to run

```bash
psql -d your_database -f q01_pharmacy.sql
```

Each file is re-runnable. It drops and recreates its own schema (`q01` ... `q10`), so the ten questions can live in the same database without table-name clashes (Q2, Q5 and Q10 all have a `students` table). Output from the demo queries and `EXPLAIN` plans prints as the script runs.

## Notes

- **Seed dates** use `CURRENT_DATE` offsets, so overdue loans, past appointments and so on stay valid whenever the script is run.
- **Failure tests** (unknown IDs, bad input, clashes) are written as commented-out lines marked "fails on purpose". Uncomment one at a time to see the error.
- **EXPLAIN**: the sample tables are tiny, so PostgreSQL would normally choose a sequential scan. The scripts run `SET enable_seqscan = off;` just before each `EXPLAIN` to show that the index is usable, then `RESET` it.
- **search_path**: every function, procedure and trigger function has `SET search_path = qNN`, so it still finds its tables when pg_cron runs it (cron sessions don't use my search_path).
- **pg_cron setup**: needs `shared_preload_libraries = 'pg_cron'` and `cron.database_name` set to the database in `postgresql.conf`. The schedule uses the server's cron time zone (UTC unless `cron.timezone` is set, in pg_cron 1.5+). `cron.schedule` with a job name replaces an existing job of the same name, so rerunning a script doesn't create duplicate jobs.
- **Q3 assumption**: `pr_refresh_overdue` counts loans that are unreturned as of the date *and* past their due date, since the table is `overdue_summary`. The total fine is the same either way.
