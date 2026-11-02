# Pingerer GitHub Action

Keep [Pingerer](https://pingerer.com) quiet while you deploy, then make sure
your site came back. Pause alerts or open a maintenance window before the
deploy, end it afterwards, and run a post-deploy smoke check that fails the
workflow if the site isn't up.

It downloads the `pingerer` command line tool for the runner (Linux,
macOS or Windows) from its GitHub Releases and runs it, so there's nothing
to install. `cli_version` pins a version.

## Set up

1. On Pingerer's **API tokens** page, create a token with **Read & write**
   access (limit it to one account if you like).
2. Add it to your repository as the secret `PINGERER_TOKEN`
   (Settings, Secrets and variables, Actions).

## A deploy with a maintenance window

During the window checks keep running and are recorded, but nothing alerts,
no incident opens and the time doesn't count against uptime. It ends on its
own after `duration`, or when you end it.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Start maintenance
        id: maintenance
        uses: pingerer-app/action@v1
        with:
          api_token: ${{ secrets.PINGERER_TOKEN }}
          action: maintenance-start
          site: yourbakery.com, shop.yourbakery.com
          duration: 15m
          message: We're deploying a new version; back in a few minutes.

      - run: ./deploy.sh

      - name: Wait until the site is up
        uses: pingerer-app/action@v1
        with:
          api_token: ${{ secrets.PINGERER_TOKEN }}
          action: wait-until-up
          site: yourbakery.com, shop.yourbakery.com
          timeout: 5m

      - name: End maintenance
        if: always()
        uses: pingerer-app/action@v1
        with:
          api_token: ${{ secrets.PINGERER_TOKEN }}
          action: maintenance-end
          maintenance_window_id: ${{ steps.maintenance.outputs.maintenance_window_id }}
```

`if: always()` ends the window even when the deploy or the smoke check
failed, so a broken deploy alerts as usual from then on.

## Pausing instead

Pausing stops the checks altogether (nothing is recorded), and resuming
starts them again:

```yaml
      - uses: pingerer-app/action@v1
        with:
          api_token: ${{ secrets.PINGERER_TOKEN }}
          action: pause
          site: yourbakery.com
          monitor: mon_8xKq2    # single monitors work too

      - run: ./deploy.sh

      - uses: pingerer-app/action@v1
        if: always()
        with:
          api_token: ${{ secrets.PINGERER_TOKEN }}
          action: resume
          site: yourbakery.com
          monitor: mon_8xKq2
```

## A smoke check on its own

`check-now` runs each uptime check (http, tcp and ping monitors) once, now,
and fails if any fails. `wait-until-up` keeps checking every `interval` until
they all pass, and fails the workflow after `timeout`.

```yaml
      - uses: pingerer-app/action@v1
        id: smoke
        with:
          api_token: ${{ secrets.PINGERER_TOKEN }}
          action: check-now
          site: yourbakery.com
          region: iad

      - run: jq . <<<"$RESULTS"
        env:
          RESULTS: ${{ steps.smoke.outputs.results }}
```

These test runs aren't recorded and don't change the monitor's status; the
monitor's own schedule carries on as usual.

## Inputs

| Input | For | Default | |
| --- | --- | --- | --- |
| `api_token` | all | | A read and write API token. Required. |
| `action` | all | | `pause`, `resume`, `maintenance-start`, `maintenance-end`, `check-now` or `wait-until-up`. Required. |
| `site` | all | | Site ids (`site_8xKq2`) or hosts (`yourbakery.com`), comma or newline separated. |
| `monitor` | pause, resume, check-now, wait-until-up | | Monitor ids (`mon_8xKq2`), comma or newline separated. |
| `duration` | maintenance-start | `15m` | How long the window lasts: `30s`, `15m`, `2h`. |
| `title` | maintenance-start, maintenance-end | `Deploy` | The window's title. Without `maintenance_window_id`, maintenance-end ends the in-progress windows with this title on `site`. |
| `message` | maintenance-start | | What your status page says. |
| `maintenance_window_id` | maintenance-end | | The window to end (maintenance-start's output). |
| `timeout` | wait-until-up | `5m` | How long to wait before failing. |
| `interval` | wait-until-up | `15s` | How long between checks. |
| `region` | check-now, wait-until-up | | The region to check from, like `fsn` or `iad`. |
| `account` | all | | The account id (`acct_...`), if the token's person has several. |
| `base_url` | all | `https://pingerer.com` | Another Pingerer server. |
| `cli_version` | all | `latest` | The `pingerer` tool's version, like `0.3.0`. |

Subscribers to your status page aren't emailed about a maintenance window
the action opens.

## Outputs

| Output | |
| --- | --- |
| `maintenance_window_id` | The window maintenance-start opened, or those maintenance-end ended. |
| `status` | `up` or `down`, from check-now and wait-until-up. |
| `results` | Each check's result as JSON: `[{"id": "mon_...", "ok": true, "status_code": 200, "latency_ms": 143, "region": "fsn", "error": null}]`. |

## The same from the command line

The [`pingerer` CLI](https://github.com/pingerer-app/pingerer) does all of this too, for other CI systems:

```sh
pingerer maintenance start --sites yourbakery.com --for 15m   # prints the window's id
pingerer sites pause yourbakery.com
pingerer wait-until-up yourbakery.com --timeout 5m
pingerer maintenance end mw_4Tq8
```

## Developing

```sh
(cd ../cli-rs && cargo build)
bash test/run_tests.sh   # runs `pingerer github-action` against test/fake_api.py
```

`.github/workflows/test.yml` runs these and the action itself once this
directory is its own repository.

### Publishing

This folder is published to github.com/pingerer-app/action by
`bin/publish-cli` in Pingerer's main repository (`bin/publish-cli action
v1.0.1` tags a release and moves `v1`). Listing it on the GitHub Marketplace
is a box to tick when drafting a release there.

## License

MIT. See [LICENSE](LICENSE).
