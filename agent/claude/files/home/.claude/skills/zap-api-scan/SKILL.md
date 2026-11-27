---
name: zap-api-scan
description: Run an OWASP ZAP API scan (DAST) of the current project's HTTP API by driving the ZAP daemon on the user's host through the zap-api-scan client, and turn the report into verified findings. Use when asked to run ZAP, a DAST or dynamic security scan, or an OWASP API scan of this project's REST (OpenAPI) or GraphQL API. SOAP is not supported. Skipped (exit 78) when ZAP is not configured. Starts the project's API and sends real requests, including POST, PUT and DELETE, so it needs a disposable database. Never run it implicitly from a read-only review.
---

# ZAP API scan

`zap-api-scan` (installed in the image at `/usr/local/bin/zap-api-scan`; in the jarvis-engineer repo itself it is `scripts/zap-api-scan.sh`) is a client of a ZAP daemon that runs on the user's host. Nothing runs ZAP inside the sandbox: the script talks to the daemon over its REST API (`ZAP_URL`, `ZAP_API_KEY`), the daemon sends the scan traffic to the API through a port published on the host, and the script writes `report.html` and `report.json`. Run `zap-api-scan -h` for every option and exit code.

## Safety gate (check before anything else)

Every scan writes. Importing the definition sends one generated request per operation, POST, PUT and DELETE included; `--active` adds attack payloads.

- Run it only when the user asked for a scan. A reviewer that is read-only by its role does not start services or run this skill.
- The API must use a disposable database (a local container, a test schema, an in-memory store). Find out from the project's configuration which database the API will connect to. If it is shared, remote or you cannot tell, stop and ask the user.
- `--active` only when the user asked for it or for injection-class coverage. Without it, ZAP checks only what the responses show (headers, cookies, information leaks), not injection, path traversal or SSRF.
- Targets are this sandbox's loopback only (`localhost`, `127.0.0.1`, `[::1]`), and `-f soap` is refused; the wrapper enforces both. Do not try to work around that.
- **The key is a host-side capability.** Anyone holding `ZAP_API_KEY` in the sandbox can make the host's ZAP send HTTP requests from the host to anything the host can reach (its own localhost services, the LAN, cloud metadata), outside the sandbox's network policy. The wrapper's checks restrict the script, not the key. The user accepted this risk and may keep the daemon running long-term. Use the key for nothing except `zap-api-scan`: never call the ZAP API yourself, never print the key, never write it to a file.

## Not configured (exit 78)

Exit 78 with `ZAP is not configured` (or another 78 message) means the scan was skipped. Report "skipped: ZAP not configured" and stop. It is not a pass and not an error to debug: do not retry, do not set the variables, do not start ZAP yourself. If the user asks how to set it up, give them the steps below.

### Host setup (the user runs these on the host)

1. Generate a key once, put the variables in the `.env` the sandbox is created with (for jarvis-engineer sandboxes, that repo's `.env`), then recreate the sandbox: `--env-file` is read only at create time.
   ```sh
   openssl rand -hex 32
   ```
   ```sh
   ZAP_URL=http://host.docker.internal:8090
   ZAP_API_KEY=<the hex key>
   # ZAP_TARGET_HOST=host.docker.internal   # default; localhost for native ZAP or Linux --network host
   ```
2. Start the daemon. The host port must equal ZAP's `-port` (ZAP checks the `Host` header):
   ```sh
   set -a; . ./.env; set +a
   docker run -d --rm --name zap-daemon -p 127.0.0.1:8090:8090 \
     zaproxy/zap-stable:2.17.0@sha256:9624669db72f54d86c4b46a7064518bd9bf79d8c61a4c31befa9923489f328af \
     zap.sh -daemon -host 0.0.0.0 -port 8090 \
       -config api.key="$ZAP_API_KEY" \
       -config api.addrs.addr.name='.*' -config api.addrs.addr.regex=true \
       -config api.filexfer=true
   ```
   - `-host 0.0.0.0` applies inside the container; the host binding stays `127.0.0.1`.
   - Linux Docker Engine: use `--network host`, `-host 127.0.0.1` and no `-p`, and set `ZAP_TARGET_HOST=localhost`.
   - Native ZAP: `zap.sh -daemon -host 127.0.0.1 -port 8090 -config api.key=... -config api.filexfer=true`, with `ZAP_TARGET_HOST=localhost`.
3. Stop it when finished, if wanted: `docker stop zap-daemon` (`--rm` also clears its transfer dir). Optional: the user accepted a long-running daemon.
4. Publish the API port of each sandbox to the host, at creation (`jarvis-sandbox claude --publish 8080`, repeatable, `PORT` means `PORT:PORT`) or later with `sbx port publish <sandbox> 8080:8080`.

## Procedure

1. **Find the API surface.** From the repository (README, Makefile, `docker-compose.yml`, `package.json` scripts, `cmd/` or `main.go`, framework config), work out how the API starts, which port it listens on, and its definition:
   - OpenAPI: a served spec (`/openapi.json`, `/swagger.json`, `/swagger/doc.json` for Go swag, `/v3/api-docs` for Spring, `/openapi.json` for FastAPI) or a file in the repo (`openapi.yaml`, `docs/swagger.json`). Prefer the served URL: it matches the running code.
   - GraphQL: the endpoint URL (`/graphql`, `/query`).
   - SOAP is not supported (ZAP has no host override for a WSDL). Say so and stop.
   If the project has no HTTP API, say so and stop.
2. **Start the API** in the background, bound to `0.0.0.0` (not only `127.0.0.1`): ZAP reaches it through the host-published port, which arrives on the sandbox's network interface, not loopback. Use the project's own start command and a disposable database. Wait until the definition URL answers (`curl -fsS <url> >/dev/null` in a bounded retry loop), and keep the process id to stop it later.
3. **The port must be published to the host.** Listing published ports is a host command, so you cannot check it from here. If unsure, run the scan: an unpublished port gives exit 3 with the exact publish command (step 6).
4. **Pick a report directory outside the repository**, so no scan output is left in the working tree: `out="${TMPDIR:-/tmp}/zap-reports/$(basename "$PWD")"`.
5. **Run the scan.** Use the form that matches step 1:
   ```sh
   zap-api-scan -t http://localhost:8080/openapi.json -f openapi -o "$out"                      # served OpenAPI
   zap-api-scan -t ./api/openapi.yaml -f openapi --host-port 8080 -o "$out"                     # OpenAPI file: --host-port is required
   zap-api-scan -t http://localhost:4000/graphql -f graphql -o "$out"                           # GraphQL
   ```
   `-t` is this sandbox's view; ZAP is given `http://$ZAP_TARGET_HOST:<host port>` instead. The host port defaults to the port in `-t` (the `8080:8080` convention); pass `--host-port P` when the API is published on another host port. Add `--active` per the safety gate. The passive scan takes seconds to minutes, an active scan much longer: give the command a long timeout or run it in the background.
6. **Read the exit code.**
   - 0: no FAIL and no WARN, or only WARNs under `--no-fail-on-warn`. It does not mean no alerts: INFO and IGNORE alerts still appear in the report. Read `report.json` in every case (step 7).
   - 1: at least one FAIL.
   - 2: warnings only. This is normal: every alert is a WARN unless `-c` says otherwise.
   - 3: no usable result. The output says why: the API did not answer locally (bind address, port), the import reached nothing, a timeout, a ZAP API error mid-scan, or requests went to another site. When the output says to run `sbx port publish`, give the user that exact line and stop. It is `sbx port publish <sandbox> P:<port>`, where `<sandbox>` is `$SANDBOX_NAME`, else the hostname (sbx sets it to the sandbox name). Do not retry in a loop.
   - 64: bad arguments (SOAP and the removed `-O`, `-g` and `-- ZAP_ARGS` included).
   - 66: definition or rules file missing.
   - 69: `curl` or `jq` missing, or the daemon is unreachable or rejected the request (wrong key, `Host` header or permitted address). Tell the user; do not debug the daemon.
   - 78: not configured. See "Not configured" above.
   Never report a 3, 69 or 78 as a pass.
7. **Turn alerts into findings.** Read `"$out/report.json"`: `site[].alerts[]` carries `name`, `pluginid`, `riskcode` (a string, `"3"` High to `"0"` Informational), `confidence`, `cweid`, `solution` and `instances[]` (`method`, `uri`, `param`, `evidence`). For example:
   ```sh
   jq -r '.site[].alerts[] | select((.riskcode|tonumber) >= 1) | "\(.riskdesc)\t\(.name)\tCWE-\(.cweid)\t\(.instances|length) instance(s)"' "$out/report.json"
   ```
   The URIs name `$ZAP_TARGET_HOST` and the host port, not `localhost`. ZAP reports symptoms, not causes, and has false positives. For each alert, find the handler or middleware that produced the response and confirm the defect in the code before you report it. Report confirmed alerts in the format the calling role uses (the code-review rule's finding format in a review), with the alert name, CWE, method and URI as evidence. List unconfirmed or Informational alerts apart from the findings, or leave them out, and say which you did.
8. **Clean up.** Stop the API process you started and any database container you started for it. Leave the report directory where it is and give the user its path. The ZAP daemon is the user's: leave it running.

## Options worth knowing

- **Authenticated APIs:** `--header-env VAR`, where `$VAR` holds `Name: value` (for example `API_AUTH='Authorization: Bearer ...'`, exported in your shell from a test credential). The script adds the header to every scan request of this site through a ZAP replacer rule and removes the rule at exit. Never write the value to a file or your output. Without auth, protected operations answer 401 and the scan says little about them. Say so in your result.
- **Rule tuning:** `-c FILE`, tab-separated `id<TAB>LEVEL<TAB>name` lines (`#` comments), LEVEL one of `IGNORE`, `INFO`, `WARN`, `FAIL`. Use it when the project wants a pass/fail gate. The rule ids are the alerts' `pluginid`.
- **Reports only, no failing exit code:** `--no-fail-on-warn`.
- **Ports and time:** `--host-port P` (see step 5; 80 and 443 are refused), `--timeout MIN` (bound for each scan wait, default 10).
- **Active scan:** `--active` (see the safety gate).

Caveats of the shared daemon:

- `IGNORE` only filters the result here: the rule still runs, because changing the scan policy would change it for every sandbox.
- One scan per published host port at a time: a second run against the same site deletes the first run's results.
- The daemon's transfer dir keeps every uploaded spec and report, and any key holder can download them.
- The default active scan policy is shared by every sandbox; a change in the ZAP UI changes all of them.
