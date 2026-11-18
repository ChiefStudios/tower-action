# tower-action

Deploys the current ref through [tower](https://github.com/ChiefStudios/Tower) using a GitHub OIDC token. No deploy secret is stored in the calling repo.

What it does:

1. Requests an OIDC token from GitHub with audience `tower`.
2. POSTs it to `<url>/api/ci/deploy`. tower looks up the binding for the repo and branch and starts the deploy.
3. Polls tower until the deploy is finished.
4. The job fails unless the final status is `success`.

## Usage

```yaml
permissions:
  contents: read
  packages: write
  id-token: write   # required: lets the job request the OIDC token

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # ... build and push the image ...
      - name: Deploy via tower
        if: github.ref == 'refs/heads/main'
        uses: ChiefStudios/tower-action@v1
        with:
          url: https://tower.example.com
```

## Inputs

| Input | Required | Default | Meaning |
| --- | --- | --- | --- |
| `url` | yes | | Base URL of your tower instance. |
| `timeout-minutes` | no | `15` | How long to wait for the deploy to finish. |

## Requirements

- `permissions: id-token: write` on the job.
- `jq` and `curl` on the runner. Both are present on GitHub-hosted Ubuntu runners.
- A binding in tower for the repo and branch (add it on the dashboard's Bindings page, which also has a Workflow button with a ready-made snippet).

## Errors

| Message | Meaning |
| --- | --- |
| `no tower binding for <repo>@<ref>` | tower has no enabled binding for this repo and branch (HTTP 403). Add one, or check that the binding is enabled. |
| `tower rejected the OIDC token (invalid, expired or replayed)` | HTTP 401. The token failed verification. Re-run the job; check `id-token: write` and the `OIDC_AUDIENCE` setting on tower. |
| `tower is busy, giving up` | Coolify's queue was full (HTTP 503) on three attempts. Re-run later. |
| `timed out waiting for deploy (last status: ...)` | The deploy did not reach a final status within `timeout-minutes`. It may still finish; check the dashboard. |
| `deploy ended as <status>` | The deploy finished but not as `success` (for example `failed` or `cancelled`). |
| `tower deploy request failed (HTTP <code>)` | Any other response, or tower could not be reached. Check `url`. |
| `tower returned an unexpected response` | The reply was not a deploy ticket. Check that `url` points at tower. |
