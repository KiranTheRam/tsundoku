# Komga integration environment

Place test CBZ, CBR, and PDF books under `fixtures`, then run:

```sh
docker compose up -d
```

Open `http://localhost:25600`, create the first user, add `/data` as a library, and grant the test user `PAGE_STREAMING`. This state is intentionally outside the application test bundle so restricted users, changed hashes, pagination, and credential expiry can be exercised against a real Komga 1.25 server.
