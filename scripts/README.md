# scripts/

Build, deploy and one-off content scripts. Run them from anywhere; each shell script `cd`s to the repo root. Deployment and teardown require AWS credentials, explicit `EXPECTED_ACCOUNT_ID`, and explicit `AWS_REGION`. Other scripts may retain their own Region defaults. Templates are in [`../infra/`](../infra/README.md).

## Files

| File | What it does |
|---|---|
| `build.sh` | Builds the Lambda package `build/oci.zip` (python3.12, x86_64): downloads Linux wheels from `requirements.txt`, copies the Python app, `features/`, `engine/`, `utils/`, `data/`, `benchmark/`, `resources/`, `evals/checks.py` and the PDF fonts, and zips with fixed mtimes so identical builds give the same hash. Usage: `scripts/build.sh`. |
| `deploy.sh` | Deploys the database stack, Astro site, Lambda API, app stack, S3 site, database migrations and Knowledge Base ingestion. `SEED_SYNTHETIC_DATA=1` explicitly replaces demo seed rows. It leaves shared Region logging settings untouched and refuses to empty a legacy StoreBucket. Requires `EXPECTED_ACCOUNT_ID` and `AWS_REGION`. Optional env: `STACK`, `DB_STACK`, `VPC_ID`, `SUBNET_IDS`, `DB_MIN_CAPACITY`, `EXTRA_DOCS`, `RESERVED_CONCURRENCY`, `MONTHLY_BUDGET_USD`, `BUDGET_ALERT_EMAIL`, `RECORD_GITHUB_DEPLOYMENT=1`. Reads `infra/.phoenix.env` when it exists. Usage: `scripts/deploy.sh`. |
| `deploy_observability.sh` | Deploys the Phoenix stack (`infra/observability.yaml`). Generates secrets once into `infra/.phoenix.env` (mode 600, never printed), waits for Phoenix through CloudFront, then creates the app's API key and the Phoenix projects. Optional env: `OBS_STACK`, `AWS_REGION`, `PHOENIX_INSTANCE_TYPE`, `PHOENIX_SNAPSHOT_ID` (first deploy only). Run it before `deploy.sh` if you want Phoenix traces. |
| `teardown.sh` | Empties the app buckets and deletes the app and database stacks, then the artifact bucket. It leaves shared logging settings and the optional Phoenix stack untouched; `DELETE_OBSERVABILITY_STACK=1` also deletes Phoenix. Final database and optional Phoenix volume snapshots are kept. Requires `EXPECTED_ACCOUNT_ID` and `AWS_REGION`. Asks you to type `delete` unless given `--yes`. Usage: `scripts/teardown.sh [--yes]`. |
| `gen_content.py` | Offline content step: asks Claude (through `pipeline._converse`) for a plain-language glossary and a Spanish questionnaire, written to `frontend/public/content/glossary.json` and `questions_es.json`. Answers stay keyed by statement id, so scoring is untouched. Usage: `python3 scripts/gen_content.py` with AWS credentials. |
| `build_pitch_pdf.py` | Renders `docs/pitch/index.html` to `docs/pitch/OCI-Capacity-Coach-pitch.pdf`, one 1920x1080 page per slide, with Playwright Chromium. Usage: `python3 scripts/build_pitch_pdf.py`. |
| `build_architecture.py` | Renders `docs/img/architecture.html` to `docs/img/architecture.png` (2x, the AWS-style diagram in the README, the technical guide and the wiki), with Playwright Chromium. Rebuild after editing the HTML. |
| `build_guide_pdf.py` | Renders `docs/technical-guide.md` (Markdown and Mermaid, through marked and mermaid from the jsDelivr CDN) to `docs/OCI-Capacity-Coach-technical-guide.pdf`, A4 with the app's fonts and page numbers, with Playwright Chromium. Needs network. Usage: `python3 scripts/build_guide_pdf.py`. |
| `build_script_docx.py` | Renders `docs/pitch/demo-script.md` to `docs/pitch/OCI-Capacity-Coach-script.docx` (Word) in the app's colours: headings, tables, lists, links. Needs python-docx. Rebuild it after editing the script. |
| `build_readme_media.py` | Builds the README media with Playwright Chromium and the ffmpeg from `imageio-ffmpeg`. `banner` renders `docs/img/banner.html` to `banner.png`. `demo` drives the live site (`APP_URL`) through the demo path with captions and a visible cursor, records it with a DevTools screencast, speeds up the AI waits and writes `docs/demo/oci-capacity-coach-demo.mp4` and `.gif`. The demo makes one Southside sample report and one chat question (about $0.11, counts against the hourly cap). Usage: `python3 scripts/build_readme_media.py banner\|demo`. |
| `build_wiki.py` | Builds the [GitHub wiki](https://github.com/ArielleTolome/everytown-oci/wiki) from the repo docs: the technical guide split into one page per section, every folder README on one page, the evals, qa, features, demo script, background docs and changelog, plus Home, sidebar and footer. Links between these docs become wiki links; other files link to GitHub. It replaces every `*.md` in the target folder. Usage: `git clone https://github.com/ArielleTolome/everytown-oci.wiki.git /tmp/oci-wiki`, `python3 scripts/build_wiki.py /tmp/oci-wiki`, then commit and push in that folder. Run it from a clean checkout so the wiki matches a commit. |

## Changing it safely

- The generated content files were reviewed and fixed by hand: re-running `gen_content.py` overwrites those fixes.
- `build.sh` decides what ships to Lambda. A new top-level module or folder the API imports must be added to its copy list.
- Never print or commit `infra/.secret` or `infra/.phoenix.env`.
- `teardown.sh` deletes all assessments and traces (only snapshots remain).
