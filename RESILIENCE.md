# Distributed Resilience & Audit Recovery Plan

This document outlines architectural strategies for resolving distributed state challenges and recovering from data anomalies.

---

## 1. End-to-End Exactly-Once in Distributed Services

When the inventory system is split into a separate service and cannot share a transaction with the currency database, a purchase is a multi-step distributed transaction.

### The Partial Failure Window
1. The user's balance is successfully debited in the Wallet Service.
2. The Wallet Service attempts to call the Inventory Service to grant the item, but:
   - The Inventory Service times out or fails (HTTP 5xx).
   - The network disconnects.
   - The Wallet Service process crashes before initiating the API call.
In these cases, we have a debit without a corresponding grant.

### The Solution: Transactional Outbox Pattern + Idempotent Retailer
We avoid direct HTTP calls to the Inventory Service inside the user's request thread. Instead, we use the **Transactional Outbox Pattern**:

1. **Transactional Step (Wallet Service)**:
   In a single database transaction, we:
   - Verify and deduct the player's balance in the `wallets` table.
   - Insert an event record into an `outbox_events` table:
     ```sql
     INSERT INTO outbox_events (event_id, player_id, item_id, payload, status)
     VALUES ('event_uuid_123', 'player_abc', 'item_xyz', '{...}', 'PENDING');
     ```
   Because these occur in the same transaction, either both the debit and outbox event are saved, or neither is.

2. **Asynchronous Retry Step (Outbox Worker)**:
   A background worker polls the `outbox_events` table for `PENDING` rows.
   - It calls the Inventory Service: `POST /v1/inventory/grant` passing the `event_id` as the `Idempotency-Key` HTTP header.
   - Upon receiving a success response (`200 OK` or cached success), the worker updates the outbox row to `COMPLETED` (or deletes it).
   - If the call fails or times out, the worker retries with exponential backoff.

3. **Inventory Service Deduplication**:
   The Inventory Service *must* enforce idempotency using the `Idempotency-Key` (which is the outbox `event_id`). If it receives a retry for `event_uuid_123`, it returns the cached success response without granting the item again.

This guarantees that every debit has exactly one grant, even under severe crash scenarios.

---

## 2. Recovery Plan: Currency Double-Grant Incident

### Detection Strategy
To detect the double-granted currency without system downtime:
1. **Ledger Auditing**: Run a reconciliation batch script comparing the cached wallet balance against the source ledger. In a robust system, every balance change is backed by a row in a double-entry ledger table:
   ```sql
   SELECT player_id, SUM(amount) AS ledger_sum FROM wallet_ledger GROUP BY player_id;
   ```
2. **Reconciliation**: Compare `ledger_sum` with `wallets.balance`. Any discrepancy indicates a corrupted state.
3. **Duplicate Event Check**: Identify multiple ledger credit rows sharing the same source business event ID (e.g. duplicate credits for the same `battle_id` or `purchase_id`):
   ```sql
   SELECT source_event_id, COUNT(*) FROM wallet_ledger
   GROUP BY source_event_id HAVING COUNT(*) > 1;
   ```

### Correction Strategy
Once the affected players and the exact over-granted amounts are identified, we perform a zero-downtime correction:
1. **Inject Correction Transactions**: Write a script that inserts a negative adjustment ledger entry (e.g., `type = 'RECONCILIATION_CLAWBACK'`) for the over-granted amount for each affected player, and updates their wallet balance.
2. **Handle Negative Balances**:
   - If the player has already spent the currency, the balance will become negative.
   - **Business Decision**: We allow the balance to go negative. The player's balance remains negative, and any future earnings (e.g. battle payouts, credits) will automatically go toward settling the debt until the balance returns to $\ge 0$. This prevents losing money while keeping the service running.

### Prevention & Audit Trails
To catch or prevent this bug sooner in the future:
1. **Business Event Unique Constraints**: Ensure the ledger table has a unique database index on the source business event (e.g. `UNIQUE INDEX idx_event_unique (source_event_type, source_event_id)`). This hard database constraint will prevent a double-grant at the schema level, throwing an error immediately if the application tries to insert a second credit for the same event.
2. **Continuous Reconciliation Jobs**: Run an automated cron job every hour that validates the ledger sum against the wallet balance for all active players, alerting engineers immediately upon any drift.
