# Durable Game Economy Service

A robust, transactional game economy backend service that guarantees **exactly-once correctness** and **durability** under concurrent requests, retries, and hard process crashes (`kill -9`).

This service satisfies the core requirement: **never lose or duplicate a player's money or items**.

---

## Technical Stack
- **Language & Runtime**: C# / .NET 10 (ASP.NET Core Web API)
- **Database**: 
  - **PostgreSQL 16** (used in Docker environment)
  - **SQLite** (used for local zero-dependency runs and automated test isolation)
- **Query Engine**: Dapper (lightweight ADO.NET wrapper)
- **Automated Tests**: xUnit & Microsoft.AspNetCore.Mvc.Testing

---

## Prerequisites
- **To run locally**: [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- **To run in Docker**: [Docker Desktop](https://www.docker.com/products/docker-desktop/) and Docker Compose

---

## Quick Start (Run Locally)

The service can be run locally with zero dependencies. It will automatically create and migrate a local SQLite database named `economy.db` in the working directory.

1. **Clone the repository** (if downloaded as a zip, navigate to the folder).
2. **Build and run the Web API**:
   ```bash
   dotnet run --project src/DurableGameEconomy.csproj
   ```
   The service will start and listen on `http://localhost:8080`.

---

## Run in Docker (PostgreSQL)

To run the application alongside a PostgreSQL database using Docker:

1. **Build and start the containers**:
   ```bash
   docker-compose up --build
   ```
2. The PostgreSQL database container will start, perform health checks, and once ready, the Web API will start and listen on `http://localhost:8080`.
3. Data is persisted in a Docker volume named `pgdata` so it survives container restarts.

---

## Running Automated Tests

A comprehensive integration test suite covers functional logic, data validation, idempotency caching, and parallel race conditions:

```bash
dotnet test
```

*Note: The tests execute against isolated temporary SQLite databases that are automatically deleted during cleanup.*

---

## How to Exercise the API (curl Examples)

Every mutating endpoint requires a client-supplied `Idempotency-Key` HTTP header.

### 1. Credit Wallet (Battle Payout / Earnings)
Adds currency to the player's balance. If the player does not exist, a new wallet is automatically created.
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: cred-unique-key-101" \
  -d '{"amount": 1000, "reason": "Won battle 42"}' \
  http://localhost:8080/v1/wallets/player_1/credit
```
**Response (200 OK)**:
```json
{"playerId":"player_1","newBalance":1000}
```

### 2. Purchase an Item (Shop Transaction)
Atomically debits the price and grants the item to the player's inventory.
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: purch-unique-key-202" \
  -d '{"itemId": "sword_legendary", "price": 400}' \
  http://localhost:8080/v1/wallets/player_1/purchase
```
**Response (200 OK)**:
```json
{"playerId":"player_1","itemId":"sword_legendary","purchaseId":"9007f353-8321-4f81-8178-956ec93be81a","newBalance":600}
```

*If you retry either request with the same `Idempotency-Key` header, you will receive the exact same response without any double-credit or double-debit.*

### 3. Claim a Reward (One-Time Claim)
Claims a reward once per player.
```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: claim-unique-key-303" \
  -d '{"playerId": "player_1"}' \
  http://localhost:8080/v1/rewards/daily_gift_01/claim
```
**Response (200 OK)**:
```json
{"playerId":"player_1","rewardId":"daily_gift_01","claimedAt":"2026-07-04T01:15:30.0000000Z"}
```

*If a different idempotency key is used to claim the same reward for the same player, the API rejects it with a `409 Conflict` ("Reward already claimed").*

### 4. GET Wallet State
Returns the read-only state of a player's wallet.
```bash
curl http://localhost:8080/v1/wallets/player_1
```
**Response (200 OK)**:
```json
{
  "playerId": "player_1",
  "balance": 600,
  "inventory": ["sword_legendary"],
  "claimedRewards": ["daily_gift_01"]
}
```
