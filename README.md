# RhinoTests scan

Run a [RhinoTests](https://rhinotests.com) security scan of your web app from GitHub Actions and
fail the job when findings are open. [En español](#en-español).

The scan runs on RhinoTests' infrastructure, from the outside, the way an attacker would. Your
runner only starts it, waits and reads the result: your code never leaves the runner.

## Usage

```yaml
jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - name: RhinoTests
        uses: rhinotests-org/scan@v1
        with:
          domain: app.example.com
          token: ${{ secrets.RHINOTESTS_TOKEN }}
```

Run it after your deploy step, against the environment you just deployed.

### Before the first run

1. In RhinoTests, add and verify the domain (**Domains**).
2. Create an API token on the **CI/CD** page (https://app.rhinotests.com/cicd). It is shown once;
   that page also builds the workflow step for you.
3. In your repository, save it as a secret named `RHINOTESTS_TOKEN`
   (**Settings → Secrets and variables → Actions**).

API tokens are part of the Equipo and Auditoría plans. A token can only start scans of your
verified domains and read their result.

## Inputs

| Input             | Default | Description                                                                                        |
| ----------------- | ------- | -------------------------------------------------------------------------------------------------- |
| `domain`          | —       | The verified domain to scan, without `https://`.                                                   |
| `path`            | empty   | Scan only the app under this path, like `/tienda`. It gets its own grade, report and history.      |
| `shared-paths`    | empty   | Up to 5 paths that app also uses, separated by commas, like `/api`. Only with `path`.              |
| `token`           | —       | Your API token. Always pass it from a secret.                                                      |
| `profile`         | `quick` | `quick`, `standard` or `full`. Each has a fixed price in credits, the same as in the app.          |
| `fail-on`         | `high`  | Fail the job when a finding of this severity or higher is open: `none`, `low`, `medium` or `high`. |
| `timeout-minutes` | `75`    | How long to wait before failing the job. The scan itself keeps running.                            |

`fail-on` looks at every open finding of the domain (or of the path, when you set one, plus what
belongs to the whole domain: TLS, DNS and files at the root) after the scan, new or old. Use `none` to
report without blocking.

## Outputs

| Output                          | Description                              |
| ------------------------------- | ---------------------------------------- |
| `scan-id`                       | Identifier of the scan.                  |
| `status`                        | `done` or `failed`.                      |
| `grade`                         | Security grade of the domain, A to F.    |
| `open`, `high`, `medium`, `low` | Open findings, in total and by severity. |
| `report-url`                    | Link to the report in RhinoTests.        |

The grade, the counts and the link are also written to the job summary.

```yaml
- name: RhinoTests
  id: rhino
  uses: rhinotests-org/scan@v1
  with:
    domain: app.example.com
    token: ${{ secrets.RHINOTESTS_TOKEN }}
    fail-on: none
- run: echo "Grade ${{ steps.rhino.outputs.grade }}, ${{ steps.rhino.outputs.open }} open"
```

## Good to know

- **Cost.** A quick scan takes about two minutes; a full one can take an hour. The runner waits
  that long, so the job uses your Actions minutes as well as your RhinoTests credits.
- **One scan per domain at a time.** Two pipelines scanning the same domain at once make the second
  one fail. Use a `concurrency` group if that can happen.
- **Your firewall.** Scans come from the fixed IP shown in the app's New scan page. Allow that IP in
  your WAF or CDN, not GitHub's.
- **Exit codes.** `1` when findings at or above `fail-on` are open, `2` when the scan could not run
  or failed.
- **Requirements.** `bash`, `curl` and `jq` on the runner (GitHub-hosted runners have them).
- **What it sends.** The domain, the paths, the profile and your token, over HTTPS, only to
  `app.rhinotests.com`. The action is a single shell script, [`scan.sh`](scan.sh), with no
  third-party dependencies: read it before you trust it.

## Versions

`v1` is a moving tag that follows the latest 1.x release. Pin a full version (`v1.0.0`) or a commit
SHA if you prefer updates to be explicit.

## Security

Found a problem in this action? See [SECURITY.md](SECURITY.md).

## En español

Corre un escaneo de seguridad de RhinoTests sobre tu app web desde GitHub Actions y haz que el
pipeline falle si quedan hallazgos abiertos.

1. En RhinoTests, agrega y verifica el dominio (**Dominios**).
2. Crea un token en la página **CI/CD** (https://app.rhinotests.com/cicd). Se muestra una sola vez;
   esa página también te arma el paso del workflow.
3. En tu repositorio, guárdalo como secreto con el nombre `RHINOTESTS_TOKEN`
   (**Settings → Secrets and variables → Actions**).
4. Agrega el paso después de tu deploy:

```yaml
- name: RhinoTests
  uses: rhinotests-org/scan@v1
  with:
    domain: app.ejemplo.com
    token: ${{ secrets.RHINOTESTS_TOKEN }}
```

Si tu dominio tiene varias apps por ruta, agrega `path: /tienda` para escanear solo esa app: tiene su
propia nota, reporte e historial. Con `shared-paths: /api` incluyes rutas que también usa (hasta 5).

`profile` acepta `quick` (rápido, por defecto), `standard` (estándar) o `full` (completo), con el
mismo precio en créditos que en la app. `fail-on` (por defecto `high`) hace fallar el pipeline si
queda abierto algún hallazgo de esa severidad o mayor; con `none` solo informa. El escaneo corre en
la infraestructura de RhinoTests: tu código no sale del runner.
