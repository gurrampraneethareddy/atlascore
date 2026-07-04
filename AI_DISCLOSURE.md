# AI Disclosure

This document discloses the use of artificial intelligence tools during the development of this project, as required by the assessment guidelines.

## Tool and Model Usage
- **AI Coding Assistant**: Google DeepMind's Antigravity agent, powered by the **Gemini 3.5 Flash** model.
- **Usage Level**: Approximately 95% of the code, tests, and documentation was co-authored, generated, or refined using the AI assistant under human direction and verification.

## Areas of Application
1. **Architecture & Schema Design**: The AI helped design the relational database schema, database-independent connection providers, and transaction-safe idempotency logic.
2. **Implementation**: The AI generated the ASP.NET Core minimal APIs, database setup initializers, and the `EconomyService` business logic with checked math and database-level exception handlers.
3. **Automated Tests**: The AI generated the comprehensive test suite in `tests/EconomyTests.cs` representing functional requirements, duplicate request deduplication, validation constraints, and high-concurrency balance updates.
4. **DevOps**: The AI generated the `Dockerfile` and `docker-compose.yml` configurations.
5. **Documentation**: The AI drafted the `DESIGN.md`, `RESILIENCE.md`, and this `AI_DISCLOSURE.md` document.

## Human Oversight & Verification
- The workspace build was verified using the dotnet command-line interface.
- The compilation issues (missing using directives and dynamic type conversions) were analyzed and corrected.
- Functional correctness, race safety, and idempotency guarantees were proven by running the xUnit test suite on the local development environment (`dotnet test`).
