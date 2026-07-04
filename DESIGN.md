# Service Design Document (Durable Game Economy)

This document details the architecture, design choices, idempotency engine, concurrency handling, and API contract of the Durable Game Economy Service.

---

## 1. Architecture Overview

The service is built as a highly concurrent, type-safe REST API using **ASP.NET Core (.NET 10)**. It supports two database providers:
1. **PostgreSQL 16**: Used for production/Docker environments, offering industry-standard ACID transactions, MVCC, and row-level locking.
2. **SQLite**: Used for local development and automated testing. It is a serverless, single-file database that supports transactional WAL mode and database-wide write serialization.

The database provider is determined automatically at startup based on the presence of the `Postgres` connection string. If configured, PostgreSQL is used; otherwise, the service falls back to SQLite.

---

## 2. Idempotency & Exactly-Once Processing

We use an `idempotency_keys` table to deduplicate requests. Every mutating request (`credit`, `purchase`, `claim`) is required to supply an `Idempotency-Key` HTTP header.

### The Transaction Flow
For any mutating request, the execution flow is wrapped in a single database transaction:

```
                  [Mutating Request Received]
                              │
               [Begin Db Write Transaction]
                              │
        [Try Insert Idempotency Key (IN_PROGRESS)]
                              ├─── (Unique Constraint Violation) ──> [Query Existing Key]
                              │                                                │
                              │                                      [Check Path & Body Hash]
                              │                                        ├─── (Mismatch) ──> [400 Bad Request]
                              │                                        │
                              │                                      [Check Status]
                              │                                        ├── (IN_PROGRESS) ─> [409 Conflict]
                              │                                        └── (COMPLETED) ───> [Return Cached Response]
                              │
                    (Insert Succeeds)
                              │
                  [Acquire Wallet Row Lock]
                              │
                   [Validate Business Rules]
                              ├─── (Fails: e.g. Insufficient Funds) ─> [Update Key with Error Response]
                              │                                        [Commit Transaction]
                              │                                        [Return Error Response]
                              │
                   [Execute Business Logic]
             (Update wallet / Inventory grant)
                              │
          [Update Idempotency Key (COMPLETED, Body)]
                              │
                 [Commit Db Write Transaction]
                              │
                   [Return OK Response]
```

### Crash Resilience (`kill -9`)
1. **Crash Mid-Transaction**: If the server process is killed with `kill -9` while a purchase or credit is executing, the database transaction is immediately rolled back by the database engine. The wallet balance remains unchanged, no inventory item is granted, and the idempotency record is removed. When the client retries the request, the server treats it as a new transaction and executes it.
2. **Crash Post-Commit but Pre-Response**: If the database transaction commits successfully (writing balance changes, inventory items, and the `COMPLETED` idempotency key to disk) but the process crashes before the HTTP response reaches the client, the client will retry the request. The server finds the existing `COMPLETED` idempotency key in the database and returns the cached response. The operation is applied exactly once.

### Key Collision Prevention
To prevent clients from reusing an idempotency key for a different request, we store the `request_path` and a SHA-256 hash of the `request_body` in the database. If a key is sent again but the path or body hash does not match, the service rejects the request with a `400 Bad Request` ("Idempotency key collision").

---

## 3. Concurrency & Locking Strategy

When multiple concurrent requests target the **same wallet**, we must prevent lost updates, race conditions, and negative balances.

### PostgreSQL (Row-Level Locking)
We execute a `SELECT balance FROM wallets WHERE player_id = @PlayerId FOR UPDATE` statement.
- This acquires an exclusive row-level lock on the player's wallet.
- Concurrent requests for the *same player* block on this statement and execute sequentially.
- Concurrent requests for *different players* proceed in parallel, maximizing throughput.

### SQLite (Database-Level Locking)
Since SQLite is an in-process file-based database, it does not support row-level locks. Instead, we start transactions with `BEGIN IMMEDIATE` (via `IsolationLevel.Serializable` in the .NET SQLite provider).
- This acquires a write lock on the database file immediately.
- Only one write transaction can be active at a time, serializing all writes and preventing deadlock (`SQLITE_BUSY`) errors.

---

## 4. Input Safety & Overflow Protection

To protect the server against malformed, malicious, or overflowing inputs:
- **Checked Math**: All balance arithmetic is run in a C# `checked` context (e.g., `checked(balance + amount)`). If an addition overflows `Int64.MaxValue`, it throws an `OverflowException` which is caught and returned as a `400 Bad Request` rather than wrapping around.
- **Null & Type Safety**: Deserialization is done manually inside try-catch blocks. If a client sends malformed JSON, a float instead of an integer, or an overflowing number, the JSON deserializer fails immediately and the server returns a `400 Bad Request` instead of crashing.
- **Constraints**: Length limits (e.g., maximum 100 characters for IDs) are validated at the boundary using `System.ComponentModel.DataAnnotations`. The database schema enforces a non-negative balance check constraint: `CHECK (balance >= 0)`.

---

## 5. API Contract Specifications

### Response Codes & Bodies

#### 1. Credit Wallet
* **Route**: `POST /v1/wallets/{playerId}/credit`
* **Success (200 OK)**:
  ```json
  {
    "playerId": "player_123",
    "newBalance": 150
  }
  ```

#### 2. Purchase Item
* **Route**: `POST /v1/wallets/{playerId}/purchase`
* **Success (200 OK)**:
  ```json
  {
    "playerId": "player_123",
    "itemId": "sword_01",
    "purchaseId": "e3b8b14e-b01b-432d-9441-2a07c3f87532",
    "newBalance": 50
  }
  ```
* **Failure - Insufficient Funds (400 Bad Request)**:
  ```json
  {
    "error": "Insufficient funds. Required: 150, Available: 50."
  }
  ```

#### 3. Claim Reward
* **Route**: `POST /v1/rewards/{rewardId}/claim`
* **Success (200 OK)**:
  ```json
  {
    "playerId": "player_123",
    "rewardId": "reward_daily_gold",
    "claimedAt": "2026-07-04T01:00:00.0000000Z"
  }
  ```
* **Failure - Already Claimed (409 Conflict)**:
  ```json
  {
    "error": "Reward reward_daily_gold has already been claimed by player player_123."
  }
  ```

#### 4. GET Wallet State
* **Route**: `GET /v1/wallets/{playerId}`
* **Success (200 OK)**:
  ```json
  {
    "playerId": "player_123",
    "balance": 50,
    "inventory": ["sword_01"],
    "claimedRewards": ["reward_daily_gold"]
  }
  ```

### Limits
- **Wallet Balance / Price / Credit Amount**: 64-bit signed integers (`1` to `9,223,372,036,854,775,807`).
- **Identifiers (`playerId`, `itemId`, `rewardId`)**: Max 100 characters.
- **Reason string**: Max 255 characters.
