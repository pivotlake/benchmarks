# Benchmark automation

`benchmark.yml` runs the benchmarks on AWS machines and puts the results in S3;
`deploy-web.yml` builds the website from them and publishes it to benchmark.pivotlake.io.
Both are run by hand from the Actions tab.

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
   boot: clones the branch, runs `benchmarks/run-and-collect.sh` for that one
   database and benchmark, uploads the result file and logs to S3, terminates
   itself. The job waits for the termination, downloads the upload, keeps it
   as the artifact `results-<benchmark>[-sf<N>]-<database>-<machine>` and, if
   the machine reported success and a result file, copies that file to the
   bucket's `latest/`. It fails if the machine died, the benchmark failed or
   produced no result; the artifact is kept either way and `latest/` is left
   alone. Cancelling the job terminates the machine.

A run job can wait at most 6 hours (GitHub's limit); the `timeout` input caps
the machine below that. A machine that outlives its job still finishes and
uploads to S3 on its own, so nothing is lost, only not promoted. A default
run is 37 jobs: eight databases on TPC-H and SSB at two scale factors each
and on ClickBench, less the combinations that don't exist.

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
└── latest/                          what the website shows: one file per database,
    └── <benchmark>/<engine>/<machine>[.sf<N>].json   benchmark, machine and scale factor,
                                     replaced by every run that succeeds
```

The artifact of a run job is that machine's folder, unchanged.

## Deploy Web

"Run workflow". A GitHub-hosted job assumes the launcher role, syncs `latest/`
into `website/results/` and bakes `website/data.js` (`website/pull-results.sh`,
which also works locally with credentials for the bucket), and hands the site
to the `gcp-builder` runner, which rsyncs it to `/var/www/benchmark.pivotlake.io` on the
site box over SSH, the way the pivot and cloud repos publish pivotlake.io, and
checks what benchmark.pivotlake.io then serves. The results are not in the repository:
a deploy publishes whatever `latest/` holds at the time.

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
