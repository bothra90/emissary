#!/bin/bash

set -e

CURR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
[ -d "$CURR_DIR" ] || { echo "FATAL: no current dir (maybe running in zsh?)";  exit 1; }
TOP_DIR=$CURR_DIR/..

# shellcheck source=common.sh
source "$CURR_DIR/common.sh"

#########################################################################################
if ! command -v helm 2> /dev/null ; then
    info "Helm doesn't exist, installing helm"
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh --version v3.4.1
    rm -f get_helm.sh
fi
thisversion=$(get_chart_version ${TOP_DIR})

repo_key=
if [[ -n "${REPO_KEY}" ]] ; then
    repo_key="${REPO_KEY}"
elif [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ; then
    repo_key=ambassador
else
    repo_key=ambassador-dev
fi
repo_url=https://s3.amazonaws.com/datawire-static-files/${repo_key}/

info "Pushing Helm Chart"
helm package --destination $TOP_DIR $TOP_DIR

# Get name of package
export CHART_PACKAGE=$(ls ${TOP_DIR}/*.tgz)

curl -o ${TOP_DIR}/tmp.yaml -k -L ${repo_url}index.yaml
if [[ $(grep -c "version: $thisversion$" ${TOP_DIR}/tmp.yaml || true) != 0 ]]; then
	failed "Chart version $thisversion is already in the index"
	exit 1
fi

helm repo index ${TOP_DIR} --url ${repo_url} --merge ${TOP_DIR}/tmp.yaml

if [ -z "$AWS_BUCKET" ] ; then
    AWS_BUCKET=datawire-static-files
fi

[ -n "$AWS_ACCESS_KEY_ID"     ] || abort "AWS_ACCESS_KEY_ID is not set"
[ -n "$AWS_SECRET_ACCESS_KEY" ] || abort "AWS_SECRET_ACCESS_KEY is not set"

info "Pushing chart to S3 bucket $AWS_BUCKET"
for f in "$CHART_PACKAGE" "${TOP_DIR}/index.yaml" ; do
    fname=`basename $f`
    echo "pushing ${repo_key}/$fname"
    aws s3api put-object \
        --bucket "$AWS_BUCKET" \
        --key "${repo_key}/$fname" \
        --body "$f" && passed "... ${repo_key}/$fname pushed"
done

info "Cleaning up..."
echo
rm ${TOP_DIR}/tmp.yaml ${TOP_DIR}/index.yaml "$CHART_PACKAGE"

if [[ -n "${PUBLISH_GIT_RELEASE}" ]] ; then
    if [[ -z "${CIRCLE_SHA1}" ]] ; then
        echo "CIRCLE_SHA1 not set"
        exit 1
    fi
    if [[ -z "${GH_RELEASE_TOKEN}" ]] ; then
        echo "GH_RELEASE_TOKEN not set"
        exit 1
    fi
    tag="chart-v${thisversion}"
    title="Ambassador Chart ${thisversion}"
    repo_full_name="datawire/ambassador"
    token="${GH_RELEASE_TOKEN}"
    description=$(cat <<-END
## :tada: Ambassador Chart ${thisversion} :tada:

Upgrade Ambassador - https://www.getambassador.io/reference/upgrading#helm.html
View changelog - https://github.com/datawire/ambassador/blob/master/charts/ambassador/CHANGELOG.md

---

END
)
    description=`echo "${description}" | awk '{printf "%s\\\n", $0}'`
    in_changelog=false
    while IFS= read -r line ; do
        if ${in_changelog} ; then
            if [[ "${line}" =~ "## v" ]] ; then
                break
            fi
            if [[ -n "${line}" ]] ; then
                description="${description}\\n${line}"
            fi
        fi
        if [[ "${line}" =~ "## v${chart_version}" ]] ; then
            in_changelog=true
        fi

    done < ${TOP_DIR}/CHANGELOG.md

    generate_post_data()
    {
        cat <<EOF
{
  "tag_name": "$tag",
  "name": "$title",
  "body": "${description}",
  "draft": false,
  "prerelease": false,
  "target_commitish": "${CIRCLE_SHA1}"
}
EOF
    }
    curl -H "Authorization: token ${token}" --data "$(generate_post_data)" "https://api.github.com/repos/$repo_full_name/releases"
fi

exit 0
