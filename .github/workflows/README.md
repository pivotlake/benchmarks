# Benchmark automation

`benchmark.yml` runs the benchmarks on AWS machines, which put their results in
S3; the site box turns those into the website on its own. `deploy-web.yml`
publishes the website's page and sets that refresh up. Both are run by hand
from the Actions tab.

## Benchmark

"Run workflow", pick the branch under "Use workflow from", edit the inputs
(they default to every database, every benchmark, SF100 and SF1000, on
c8gd.4xlarge), run. Then:

1. **plan**: one job per database, machine type, benchmark and scale factor
   (ClickBench has none); a database without an entry in a benchmark, such as
   StarRocks outside TPC-H, is skipped.
2. **run**, one job per combination, all in parallel: the runner assumes the
   launcher role (OIDC: no AWS keys anywhere) and launches an EC2 machine
   (`benchmarks/launch.sh`). The machine runs `benchmarks/cloud-init.sh.in` at
   boot: clones the branch, fetches the dataset from the bucket when it is
   there (`benchmarks/lib/dataset.sh`), runs `benchmarks/run-and-collect.sh`
   for that one database and benchmark, uploads the result file and logs to
   S3 and, when the run succeeded, copies the result to the bucket's `latest/`;
   then terminates itself. The job waits for the termination, downloads the
   upload and keeps it as the artifact
   `results-<benchmark>[-sf<N>]-<database>-<machine>`. It fails if the machine
   died, the benchmark failed or produced no result; the artifact is kept
   either way. Cancelling the job terminates the machine.

A run job waits for its machine for at most 5½ hours, then ends with a
warning: GitHub's 6-hour limit would otherwise cancel the job, and a cancelled
job terminates its machine. A machine that outlives its job still finishes,
uploads and publishes its result on its own; only the artifact is lost. The
`timeout` input caps the machine itself. A default run is
37 jobs: eight databases on TPC-H and SSB at two scale factors each and on
ClickBench, less the combinations that don't exist.

Anyone with write access to the repository can run it. Forks cannot: the
launcher role trusts only this repository's workflow runs.

## In S3

```
s3://<bucket>/
├── <database>/                      every run of a database, newest last
│   └── <date>/<time>-<run id>/      one workflow run
│       └── <benchmark>[-sf<N>]/     tpch-sf100, ssb-sf1000, clickbench, ...
│           └── <machine>/           one machine
│               ├── result.json            the result file (absent if the run produced none)
│               ├── <engine>.log           the harness log (pivot.log, pivot-parquet-partitioned.log, ...)
│               ├── run.log                run-and-collect.sh's output
│               ├── cloud-init-output.log  everything the machine did, from boot
│               └── meta.json              what ran, the disk, the exit status, and `path`:
│                                          the file's name under latest/; written last
├── latest/                          what the website shows: one file per database,
│   └── <benchmark>/<engine>/<machine>[.sf<N>].json   benchmark, machine and scale factor,
│                                    replaced by every run that succeeds. Public.
└── datasets/<suite>/sf<N>/          the datasets the machines fetch (lib/dataset.sh)
```

The artifact of a run job is that machine's folder, unchanged.

## The website

The page, `website/index.html`, loads two files beside it: `queries.js`, the
query texts, baked by Deploy Web from the repository; and `data.js`, the
results, which the site box rebuilds itself. Deploy Web installs
`website/refresh-results.sh` and `generate-results.sh` in `~/benchmark-refresh`
on the box with a cron line every five minutes: the script lists the bucket's
`latest/` (public, no credentials), and only when a result was added, changed
or removed since its last run does it sync and rebuild `data.js` into the
docroot. So a run's results are on the site within five minutes of its
machines finishing, with nothing to trigger.

"Run workflow" on Deploy Web after changing the page or the scripts: the
`gcp-builder` runner rsyncs the page to `/var/www/benchmark.pivotlake.io` on
the site box over SSH, reinstalls the refresh, runs it once and checks what
benchmark.pivotlake.io serves.

## Setup

The AWS side is one CloudFormation stack, [`aws/stack.yml`](../../aws/stack.yml):
a role the workflow assumes, a role for the machines, the bucket. From a shell
with admin credentials for the account:

```sh
aws cloudformation deploy --stack-name pivot-benchmarks --region eu-central-1 \
    --template-file aws/stack.yml --capabilities CAPABILITY_NAMED_IAM
    # add --parameter-overrides CreateOidcProvider=false if the account already
    # has GitHub's OIDC provider (aws iam list-open-id-connect-providers)

# Its outputs are the repository variables the workflow reads: set them
aws cloudformation describe-stacks --stack-name pivot-benchmarks --region eu-central-1 \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text |
    while read -r name value; do
        gh variable set "$(sed -E 's/([a-z])([A-Z])/\1_\2/g' <<< "$name" | tr a-z A-Z)" --body "$value"
    done
```

`aws cloudformation delete-stack` takes every permission away again (empty the
bucket first). To do it by hand instead, the stack holds:

| Variable | What it names |
|---|---|
| `AWS_ROLE_ARN` | the launcher role: trusts GitHub's OIDC provider for `repo:pivotlake/benchmarks:*` and its immutable-subject form `repo:pivotlake@<id>/benchmarks@<id>:*`; may `ec2:RunInstances`, `ec2:CreateTags`, `ec2:DescribeImages`, `ec2:DescribeInstanceTypes`, `ec2:DescribeInstances`, `ec2:TerminateInstances` on machines named `pivot-benchmarks-*`, `iam:PassRole` on the machine role, and list and read the bucket, and write its `latest/` |
| `INSTANCE_PROFILE` | the machines' instance profile: a role EC2 assumes, with `s3:PutObject` on the bucket |
| `RESULTS_BUCKET` | a private S3 bucket |
| `AWS_REGION` | where the machines launch, the bucket is, and the stack was deployed |

Disks: on a machine type with local NVMe (c6id, m6id, r6id, i4i, i3en and the
like) the machine formats the local disks at boot, stripes them into one
volume when there are several, and runs everything on them: the datasets, each
engine's storage, its spill files. The root volume then only holds the OS. A
type without local NVMe (c6a, m6a, ...) runs everything on the root volume,
sized by the `disk` input. Which it was is in `meta.json` and `run.log`.
c8gd.4xlarge, the default, is a 16-core Graviton 4 with one 950 GB NVMe; SF1000 needs
a storage type such as i4i.8xlarge (2 × 3.75 TB).

Quotas and cost: every database runs on its own on-demand machine, so a
default run is eight instances of each chosen type at once, each with its own
root volume of `disk` GB, for as long as the benchmarks take. The region's
on-demand vCPU quota must cover that; `launch.sh` waits and retries while it
or the capacity is exhausted. Machines terminate themselves when done, or at
the `timeout` plus two hours whatever happens.

Deploy Web also needs, as in the pivot and cloud repos: the variables
`PIVOT_SITE_SSH_HOST`, `GCP_PROJECT`, `GCP_RUNNER_X86`, `GCP_RUNNER_ZONE`, the
secret `GCP_SA_KEY`, and for this site `BENCH_SITE_DOCROOT` (the directory
nginx serves for benchmark.pivotlake.io) and optionally `BENCH_SITE_BASE_URL`. On the
site box, nginx needs a server block for benchmark.pivotlake.io serving that directory.
