# Build stage using .NET 10 SDK
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build-env
WORKDIR /app

# Copy solution file and project files first to leverage Docker layer caching
COPY DurableGameEconomy.slnx ./
COPY src/DurableGameEconomy.csproj src/
COPY tests/DurableGameEconomy.Tests.csproj tests/

# Restore dependencies
RUN dotnet restore DurableGameEconomy.slnx

# Copy the rest of the source code
COPY . ./

# Publish the application in Release mode
RUN dotnet publish src/DurableGameEconomy.csproj -c Release -o out

# Runtime stage using ASP.NET Core 10.0 runtime
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app

# Copy build output from build-env
COPY --from=build-env /app/out .

# Expose port 8080 for HTTP traffic
EXPOSE 8080

# Environment variables
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production

# Start command
ENTRYPOINT ["dotnet", "DurableGameEconomy.dll"]
