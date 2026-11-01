#!/usr/bin/env bash
# On the site box, from cron: when the bucket's latest/ has changed since the
# last run, sync it and rebuild the data.js the site serves; otherwise do
# nothing. latest/ is public, so no AWS credentials are involved. Deploy Web
# puts this script and generate-results.sh in ~/benchmark-refresh and
# installs the cron line.
#
# Usage: ./refresh-results.sh <bucket> <docroot> [region]
set -euo pipefail
cd "$(dirname "$0")"
bucket="$1" docroot="$2" region="${3:-eu-central-1}"
export PATH="/usr/local/bin:$PATH"   # cron's PATH lacks it, and that is where the AWS CLI installs

# Every result file and its ETag: changed, added or removed since last time?
listing=$(aws s3api list-objects-v2 --no-sign-request --region "$region" --bucket "$bucket" --prefix latest/ \
    --query 'Contents[?ends_with(Key, `.json`)].[Key, ETag]' --output text | sort)
[ "$listing" != "$(cat listing.txt 2>/dev/null)" ] || exit 0

start=$(date +%s)
aws s3 sync --no-sign-request --region "$region" --only-show-errors --delete \
    --exclude '*' --include '*.json' "s3://$bucket/latest/" results/
./generate-results.sh results . >/dev/null
# Into place in one step, so a visitor never gets a half-written file.
cp data.js "$docroot/data.js.tmp" && mv "$docroot/data.js.tmp" "$docroot/data.js"
echo "$listing" > listing.txt
echo "$(date -u '+%F %T') data.js rebuilt: $(grep -c '"benchmark"' data.js) results, in $(( $(date +%s) - start ))s"
