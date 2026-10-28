#!/bin/bash
#
# launch.sh - start one EC2 machine that runs one database on one benchmark
# unattended and terminates itself. What the Benchmark workflow's run job
# does, once per database, machine type, benchmark and scale factor; see
# .github/workflows/README.md for the AWS setup.
#
# The machine boots the latest Ubuntu 24.04 and runs cloud-init.sh.in
# (rendered here) as root: it clones the branch, runs run-and-collect.sh,
# uploads the result file and logs to S3 and shuts down. Prints the instance
# id (and sets `instance_id` in $GITHUB_OUTPUT when there is one). Needs AWS
# credentials in the environment and the variables:
#
#   database, machine    what to benchmark and on which EC2 instance type
#   benchmark, sf        the benchmark and its scale factor (empty for ClickBench)
#   key                  the benchmark's name in the S3 path: tpch-sf100, clickbench
#   engine               the database's engine directory in that benchmark
#   repo, branch         GitHub repository (owner/name) and branch to clone
#   run_id, run_url, date  the workflow run and its day, for the S3 path
#   bucket               S3 bucket the machine uploads to
#   instance_profile     IAM instance profile that may write to the bucket
#   disk                 root volume, GB (default 500)
#   timeout              seconds run-and-collect.sh may take (default 18000)
#   AWS_REGION           where to launch

set -euo pipefail
cd "$(dirname "$0")"

: "${database:?}" "${machine:?}" "${benchmark:?}" "${key:?}" "${engine:?}" "${repo:?}" "${branch:?}"
: "${run_id:?}" "${run_url:?}" "${date:?}" "${bucket:?}" "${instance_profile:?}" "${AWS_REGION:?}"
: "${sf:=}" "${disk:=500}" "${timeout:=18000}"

arch=$(aws ec2 describe-instance-types --instance-types "$machine" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text)
ami=$(aws ec2 describe-images --owners amazon \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04*" "Name=architecture,Values=$arch" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate) | [-1].ImageId' --output text)
echo "$machine is $arch, AMI $ami"

user_data=$(mktemp)
python3 - cloud-init.sh.in "$user_data" <<'PY'
import os, sys
template, out = sys.argv[1:]
text = open(template).read()
for name in ("database", "machine", "benchmark", "sf", "key", "engine", "repo", "branch", "run_id", "run_url", "date",
             "bucket", "timeout", "AWS_REGION"):
    text = text.replace(f"@{name}@", os.environ.get(name, ""))
open(out, "w").write(text)
PY

# Retried while the region is short of capacity or the account of vCPU quota;
# any other error fails at once.
retry='InsufficientInstanceCapacity|VcpuLimitExceeded|InstanceLimitExceeded'
while :; do
    if out=$(AWS_PAGER='' aws ec2 run-instances --image-id "$ami" --instance-type "$machine" \
            --iam-instance-profile "Name=$instance_profile" \
            --block-device-mappings "DeviceName=/dev/sda1,Ebs={DeleteOnTermination=true,VolumeSize=$disk,VolumeType=gp3}" \
            --instance-initiated-shutdown-behavior terminate \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=pivot-benchmarks-$key-$database-$machine},{Key=run_id,Value=$run_id},{Key=branch,Value=$branch}]" \
            --user-data "file://$user_data" --query 'Instances[0].InstanceId' --output text 2>&1); then
        echo "launched $out: $key, $database on $machine"
        [ -z "${GITHUB_OUTPUT:-}" ] || echo "instance_id=$out" >> "$GITHUB_OUTPUT"
        break
    fi
    if grep -qE "$retry" <<< "$out"; then
        echo "run-instances: $(grep -oE "$retry" <<< "$out" | head -n1) for $machine, retrying in 60s" >&2
        sleep 60
        continue
    fi
    echo "$out" >&2
    exit 1
done
