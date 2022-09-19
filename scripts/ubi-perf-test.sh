#!/usr/bin/env bash

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PATCHES_DIR="${SCRIPT_DIR}/../patches"

set -e
# set -x

# Prefix with the date and sent to stderr.
TS_FORMAT=${TS_FORMAT:-'[%Y-%m-%dT%H:%M:%S%z]:'}
err() {
    echo "$*" | ts "${TS_FORMAT}" >&2
}

# Check for required shell programs.
prereq() {
    if ! command -v ts >/dev/null 2>&1; then
        echo "'ts' is required but not available" >&2
        echo 'try: brew install moreutils' >&2
        exit 1
    fi
    if ! command -v ts >/dev/null 2>&1; then
        echo "'oc' is required but not available" >&2
        echo 'try: brew install openshift-cli' >&2
        exit 1
    fi
    if ! command -v gdate >/dev/null 2>&1; then
        echo "'gdate' is required but not available" >&2
        echo 'try: brew install coreutils' >&2
        exit 1
    fi
    if ! command -v gwc >/dev/null 2>&1; then
        echo "'gwc' is required but not available" >&2
        echo 'try: brew install coreutils' >&2
        exit 1
    fi
    if ! command -v http >/dev/null 2>&1; then
        echo "'http' is required but not available" >&2
        echo 'try: brew install httpie' >&2
        exit 1
    fi
}

# Set env vars with reasonable defaults.
set_vars() {
    # which UBI are we testing?
    UBI=${UBI:-"9"}
    if [ "${UBI}" != "8" ] && [ "${UBI}" != "9" ]; then
        err "invalid UBI value '${UBI}'"
        exit 1
    fi

    # for capturing various outputs
    TMPDIR=${TMPDIR:-/tmp/}
    SCRATCH_ROOT=${SCRATCH_ROOT:-"${TMPDIR}$(date +'%Y-%m-%dT%H.%M.%S%z')"}
    mkdir -p "${SCRATCH_ROOT}"

    # for building images and deploying
    IMAGE_TAG=${IMAGE_TAG:-"test_ubi${UBI}_"$(date '+%s')}
    QUAY_USER=${QUAY_USER:-"infinitewarp"}
    CLOUDIGRADE_DIR=${CLOUDIGRADE_DIR:-"${HOME}/projects/cloudigrade"}

    # for api port-forwarding
    PORT_LOCAL=8001
    PORT_REMOTE=8000

    # for making synthetic data requests
    SYNTHETIC_API="localhost:${PORT_LOCAL}/internal/api/cloudigrade/v1/syntheticdatarequests/"
    SYNTHETIC_REQUESTS_COUNT="${SYNTHETIC_REQUESTS_COUNT:-4}"
    SYNTHETIC_INSTANCE_COUNT="${SYNTHETIC_INSTANCE_COUNT:-1000}"
    SYNTHETIC_SINCE_DAYS_AGO="${SYNTHETIC_SINCE_DAYS_AGO:-10}"
    IS_READY_CHECK_DELAY="5"

    # for running "python -m timeit"
    TIMEIT_RUN_COUNT="${TIMEIT_RUN_COUNT:-2}"
    TIMEIT_NUMBER="${TIMEIT_NUMBER:-100}"
    TIMEIT_REPEAT="${TIMEIT_REPEAT:-2}"
    TIMEIT_FULL_LOG_DIR="${SCRATCH_ROOT}/timeit-full-logs"
    TIMEIT_DURATIONS_DIR="${SCRATCH_ROOT}/timeit-durations"

    # for spawn_logging_tasks
    LOGGING_TASKS_OUTER_LOOP="${LOGGING_TASKS_OUTER_LOOP:-20}"
    LOGGING_TASKS_INNER_LOOP="${LOGGING_TASKS_INNER_LOOP:-20}"
    LOGGING_TASKS_LOGGER_CALLS="${LOGGING_TASKS_LOGGER_CALLS:-20}"

    # output from processed cloudigrade-worker logs
    ALL_TASK_SUCCEEDED_LOG="${SCRATCH_ROOT}/all-tasks-succeeded.txt"
    ALL_TASKS_NAMES_AND_DURATIONS="${SCRATCH_ROOT}/all-tasks-name-and-duration.txt"

    # activate cloudigrade and load more ephemeral-specific environment variables
    # shellcheck source=/dev/null
    source "${HOME}/bin/cloudigrade.sh"
    # shellcheck source=/dev/null
    source "${HOME}/.env-files/ephemeral"
}

# sleep for some seconds and show progress
sleep_for() {
    local sleep_time=$1
    local reason=$2
    echo -n "sleep ${sleep_time} ${reason}" | ts "${TS_FORMAT}" >&2
    for _ in $(seq 1 "${sleep_time}"); do
        echo -n '.' >&2
        sleep 1
    done
    echo "ok." >&2
}

# Build, tag, and push cloudigrade image to quay.io.
build_and_push_image() {
    err "::build_and_push_image"

    pushd "${CLOUDIGRADE_DIR}"  2>&1 | ts "${TS_FORMAT}" >&2
    podman build . --no-cache --tag quay.io/"${QUAY_USER}"/cloudigrade:"${IMAGE_TAG}"  2>&1 | ts "${TS_FORMAT}" >&2
    podman push quay.io/"${QUAY_USER}"/cloudigrade:"${IMAGE_TAG}"  2>&1 | ts "${TS_FORMAT}" >&2
    popd  2>&1 | ts "${TS_FORMAT}" >&2
}

# Reserve a new bonfire namespace.
bonfire_reserve() {
    err "::bonfire_reserve"

    NAMESPACE=$(yes | bonfire namespace reserve --duration 8h --pool real-managed-kafka | grep -o 'ephemeral-[a-zA-Z0-9]*$')
    export NAMESPACE
    err "${NAMESPACE}"
}

# Un-deploy cloudigrade using ansible playbook.
playbook_absent() {
    err "::playbook_absent"

    pushd "${CLOUDIGRADE_DIR}" 2>&1 | ts "${TS_FORMAT}" >&2
    ANSIBLE_FORCE_COLOR=True ansible-playbook \
        -e clowder_state=absent \
        -e namespace="${NAMESPACE}" \
        deployment/playbooks/manage-clowder.yml 2>&1 | ts "${TS_FORMAT}" >&2
    popd 2>&1 | ts "${TS_FORMAT}" >&2
}

# Deploy cloudigrade using ansible playbook.
playbook_deploy() {
    err "::playbook_deploy"

    pushd "${CLOUDIGRADE_DIR}" 2>&1 | ts "${TS_FORMAT}" >&2
    CLOUDIGRADE_QUAY_USER="${QUAY_USER}" \
    CLOUDIGRADE_IMAGE_TAG="${IMAGE_TAG}" \
    ENABLE_SYNTHETIC_DATA_REQUEST_HTTP_API="True" \
    ANSIBLE_FORCE_COLOR=True \
    ansible-playbook \
        -e namespace="${NAMESPACE}" \
        -e env="${CLOUDIGRADE_ENVIRONMENT}" \
        deployment/playbooks/manage-clowder.yml 2>&1 | ts "${TS_FORMAT}" >&2
    popd 2>&1 | ts "${TS_FORMAT}" >&2
}

# Switch "oc project" to NAMESPACE or exit.
oc_project() {
    err "::oc_project"

    if [ -z "${NAMESPACE+1}" ]; then
        err "missing requried NAMESPACE"
        exit 1
    fi
    oc project -q "${NAMESPACE}" >&2
}

# Spawn a ton of perf_test_logging tasks.
# Weird looping logic tries to work around openshift killing the 'oc rsh' process prematurely.
# ~$1 is outer loop counter. $2 is inner loop counter. $3 is how many logger calls in each task~
spawn_logging_tasks() {
    err "::spawn_logging_tasks"

    local count_1
    local count_2
    local count_3
    local pod_label
    local pod_name

    count_1="${LOGGING_TASKS_OUTER_LOOP}" # outer loop count
    count_2="${LOGGING_TASKS_INNER_LOOP}" # inner loop to create tasks
    count_3="${LOGGING_TASKS_LOGGER_CALLS}" # how many loggers per task
    pod_label="cloudigrade-api"
    pod_name=$(oc get pods -o jsonpath='{.items[?(.status.phase=="Running")].metadata.name}' -l pod="${pod_label}" | awk '{print $1}')

    oc rsh -c "${pod_label}" pods/"${pod_name}" ./manage.py shell <<EOF 2>&1 | tee -a "${SCRATCH_ROOT}/oc-rsh-${pod_label}.txt" | ts "${TS_FORMAT}" >&2
from api.tasks import perf_test_logging
for _ in range($count_1):
    print([perf_test_logging.delay($count_3) for __ in range($count_2)])
EOF
}

# Run timeit with logger commands in pods.
timeit_logger() {
    err "::timeit_logger"

    mkdir -p "${TIMEIT_FULL_LOG_DIR}" "${TIMEIT_DURATIONS_DIR}"

    local pod_name
    for _ in $(seq 1 "${TIMEIT_RUN_COUNT}"); do
        for pod_label in "cloudigrade-api" "cloudigrade-worker"; do
            pod_name=$(oc get pods -o jsonpath='{.items[?(.status.phase=="Running")].metadata.name}' -l pod="${pod_label}" | awk '{print $1}')
            if [ -z "${pod_name+1}" ]; then
                err "no ${pod_label} pods found"
                exit 1
            fi
            err "rsh pods/${pod_name} python -m timeit --number ${TIMEIT_NUMBER} --repeat ${TIMEIT_REPEAT} ..."
            oc rsh -c "${pod_label}" pods/"${pod_name}" \
                python -m timeit \
                    --number "${TIMEIT_NUMBER}" --repeat "${TIMEIT_REPEAT}" --verbose --unit=msec \
                    --setup='import django; django.setup();import logging; logger=logging.getLogger();import socket; hostname=socket.gethostname();counter=0;' \
                    'counter+=1' \
                    'logger.info("%s test log %s", hostname, counter)' \
                    2>&1 | tee -a "${TIMEIT_FULL_LOG_DIR}/${pod_label}" | grep -e '\(raw times\|loops\)' | ts "${TS_FORMAT}" >&2
                # grep -v '^stdout' | grep -v -e '^[[:space:]]*$'

            # gnarly string parsing and printf are necessary
            # because *sometimes* very slow timeit calls use scientific notation
            # like "1.17e+03" instead of simply "1170". grumble grumble.
            grep 'raw times: ' "${TIMEIT_FULL_LOG_DIR}/${pod_label}" | \
                sed -E \
                    -e 's/(^.*raw times: )(.*$)/\2/g' \
                    -e 's/, / /g' \
                    -e 's/ msec//g' \
                | tr -d '\r' | xargs -n1 -I NUMBER bash -c "printf '%f' NUMBER; echo" \
                >> "${TIMEIT_DURATIONS_DIR}/${pod_label}"

            # err "${TIMEIT_DURATIONS}${pod_label}"
        done
    done
}

# Download worker logs to "${SCRATCH_ROOT}/workerlog-${pod_name}.txt".
# Warning: this deletes any previous worker logs saved in ${SCRATCH_ROOT} before downloading.
download_worker_logs() {
    err "::download_worker_logs"

    # setopt sh_word_split || true # needed for zsh because it normally doesn't split unquoted strings
    (rm "${SCRATCH_ROOT}"/workerlog-*.txt) 2>/dev/null || true

    local worker_pod_names
    local pod_name
    worker_pod_names=$(oc get pods -o jsonpath='{.items[?(.status.phase=="Running")].metadata.name}' -l pod=cloudigrade-worker)
    for pod_name in $worker_pod_names; do  # no quotes; allow spaces to expand items
        err "getting logs from ${pod_name}"
        oc logs "${pod_name}" > "${SCRATCH_ROOT}/workerlog-${pod_name}.txt"
    done

    if [ -z "${SKIP_TASKS}" ]; then
        local actual_count
        local expected_count
        expected_count=$((LOGGING_TASKS_OUTER_LOOP * LOGGING_TASKS_INNER_LOOP))
        actual_count=$(grep -c -h "Task api.tasks.perf_test_logging.*succeeded in" "${SCRATCH_ROOT}"/workerlog-*.txt | awk 'BEGIN {sum = 0;} {sum += $1;} END {print sum;}')
        err "actual ${actual_count} expected ${expected_count}"
        if [ "${actual_count}" -lt "${expected_count}" ]; then
            err "expected ${expected_count} but found ${actual_count} completed perf_test_logging tasks"
            sleep_for 30 "to give them time to complete before downloading logs again"
            download_worker_logs
            return
        fi
    fi
}

# Extract task "succeeded in" information.
# Side effect: this writes matching log lines to "${ALL_TASK_SUCCEEDED_LOG}".
# Side effect: this writes task names and durations to "${ALL_TASKS_NAMES_AND_DURATIONS}".
extract_logged_tasks() {
    err "::extract_logged_tasks"

    grep --no-filename --extended-regex \
        'Task api.tasks.[^]]+\] succeeded in [0-9.]+s: ' \
        "${SCRATCH_ROOT}"/workerlog-*.txt > "${ALL_TASK_SUCCEEDED_LOG}"

    sed -Ee \
        's/^([^ ]*) ([^ ]*) .*Task ([^[]+)+\[[^]]+\] succeeded in ([0-9.]+)s.*/\3 \4 \1T\2/' \
        "${ALL_TASK_SUCCEEDED_LOG}" > "${ALL_TASKS_NAMES_AND_DURATIONS}"
}

# port-forward an api pod if not already forwarded.
api_port_forward() {
    if ! pgrep -f "oc port-forward pods/[^ ]* ${PORT_LOCAL}:${PORT_REMOTE}" >/dev/null; then
        err "cloudigrade api is not currently port-forwarded"
        sleep_for 30 "to increase likelihood that an api is available and stable"
        local cloudigrade_api_pod_name
        cloudigrade_api_pod_name="$(oc get pods -o jsonpath='{.items[?(.status.phase=="Running")].metadata.name}' -l pod=cloudigrade-api | awk '{print $1}')"
        if [ -z "${cloudigrade_api_pod_name+1}" ]; then
            err "no cloudigrade api pods found"
            exit 1
        fi
        err oc port-forward pods/"${cloudigrade_api_pod_name}" "${PORT_LOCAL}:${PORT_REMOTE}"
        oc port-forward pods/"${cloudigrade_api_pod_name}" "${PORT_LOCAL}:${PORT_REMOTE}" 2>&1 | ts "${TS_FORMAT}" >&2 &
        sleep 1
        sleep_for 3 "briefly to deal with possible oc port-forward setup slowness"

        if ! pgrep -f "oc port-forward pods/[^ ]* ${PORT_LOCAL}:${PORT_REMOTE}" >/dev/null; then
            err "cloudigrade api port-forwarding failed"
            err "current api pods:"
            oc get pods -o jsonpath='{.items[?(.status.phase=="Running")].metadata.name}' -l pod=cloudigrade-api >&2
            exit 1
        fi

        # try a request... just to be sure.
        http "${SYNTHETIC_API}" >/dev/null 2>&1
    fi
}

# kill the backgrounded oc port-forward process.
kill_api_port_forward() {
    local pids
    pids=$(pgrep -f "oc port-forward pods/[^ ]* ${PORT_LOCAL}:${PORT_REMOTE}") || true

    local pid
    for pid in $pids; do  # no quotes here; allow spaces to expand items
        kill "${pid}" >&2
        err "killed 'oc port-forward' process with pid ${pid}"
    done
}

# Delete a deployment and wait for its new pods to come up.
# $@ list of deployment names to redeploy. (maybe)
force_redeploy() {
    err "::force_redeploy"

    local old_pods
    local old_pods_count
    local ready_pods
    local ready_pods_count

    local labels
    labels=("cloudigrade-worker")
    # echo "${labels[@]}"
    # echo "$@"
    local pod_label
    # for pod_label in "$@"; do
    for pod_label in "${labels[@]}"; do
        old_pods=$(oc get pods -o jsonpath='{.items[?(.status.phase=="Running")].metadata.name}' -l pod="${pod_label}")
        old_pods_count=$(echo "$old_pods" | gwc -w)

        oc delete deployment/"${pod_label}" 2>&1 | ts "${TS_FORMAT}" >&2
        err "deleted deployment/${pod_label}"

        ready_pods=""
        ready_pods_count="0"
        while [[ "${ready_pods_count}" != "${old_pods_count}" || "${ready_pods}" == "${old_pods}" ]]; do
            err "waiting for all new ${pod_label} pods to be ready"
            sleep 2
            ready_pods=$(oc get pods -o jsonpath='{.items[?(.status.containerStatuses[0].ready==true)].metadata.name}' -l pod="${pod_label}")
            ready_pods_count=$(echo "$ready_pods" | gwc -w)
        done
        err "all new ${pod_label} pods are now ready!"
    done
}

# HTTP post to create synthetic data.
# Side effect: replaces file(s) at "${SCRATCH_ROOT}/synthetic-${counter}.json".
# $1 is number of times to post.
# $2 is "instance count" per post.
# $3 is "since days ago" per post.
synthesize_data() {
    err "::synthesize_data"

    local request_count=$1
    local instance_count=$2
    local since_days=$3

    (rm "${SCRATCH_ROOT}"/synthetic-*.json) >&2 2>/dev/null || true
    err "synthesizing ${request_count} requests each with ${instance_count} instances since ${since_days} days ago"

    local counter
    for counter in $(seq 1 "$request_count"); do
        api_port_forward
        http --ignore-stdin "${SYNTHETIC_API}" \
            cloud_type=aws \
            image_rhel_chance=1.0 \
            instance_count="${instance_count}" \
            since_days_ago="${since_days}" \
            > "${SCRATCH_ROOT}/synthetic-${counter}.json" && \
            err "synthetic request ${counter} posted" || \
            exit 1
    done
}

# Wait until the synthetic data is ready.
# Prerequisite: files should exist at "${SCRATCH_ROOT}/synthetic-${counter}.json".
# Side-effect: writes files to "${SCRATCH_ROOT}/syntheticid-${synthetic_id}.json"
wait_until_synthetic_data_is_ready() {
    err "::wait_until_synthetic_data_is_ready"

    [ -z "${start_time}" ] && start_time=$(gdate +%s)
    # local start_time
    # start_time=$(gdate +%s)

    local synthetic_id
    local is_ready
    local end_time

    local expected_count
    # expected_count=$(ls "${SCRATCH_ROOT}"/synthetic-*.json 2>/dev/null| wc -l | awk '{print $1}')
    expected_count=$(find "${SCRATCH_ROOT}" -maxdepth 1 -name 'synthetic-*.json' | gwc -l)
    for counter in $(seq 1 "${expected_count}"); do

        synthetic_id=$(jq -r .id "${SCRATCH_ROOT}/synthetic-${counter}.json")
        err "created synthetic data request ${counter} has ID ${synthetic_id}"

        is_ready="false"
        while [ "${is_ready}" != "true" ]; do
            # need to keep retrying the port-forwarding because openshift is flaky AF.
            api_port_forward
            is_ready=$(
                http --ignore-stdin "${SYNTHETIC_API}${synthetic_id}/" |
                tee "${SCRATCH_ROOT}/syntheticid-${synthetic_id}.json" |
                jq -r .is_ready
            )
            if [ "${is_ready}" != "true" ]; then
                sleep_for "${IS_READY_CHECK_DELAY}" "because synthetic data request ID ${synthetic_id} is not ready"
            fi
        done

        end_time=$(gdate +%s)
        err "synthetic data request ID ${synthetic_id} confirmed ready after $((end_time-start_time)) seconds"
    done

    kill_api_port_forward
}

# Output results to stdout in markdown table format.
# Prerequisite: file with task names and durations should exist at "${ALL_TASKS_NAMES_AND_DURATIONS}"
output_results_task_durations() {
    err "::output_results_task_durations"

    set +x
    if [ -f "${ALL_TASKS_NAMES_AND_DURATIONS}" ]; then
        echo
        echo "## task times for image ${IMAGE}"
        echo
        echo 'task | count | totaltime | meantime | start | end | delta'
        echo ':--- | ----: | --------: | -------: | ----: | --: | ----:'

        # for each task, count number of calls and sum and average the duration
        awk -F ' ' \
            '{
                task_name = $1
                duration = $2
                competed_time = $3
                totals[task_name] += duration
                counts[task_name] += 1
                mins[task_name] = (counts[task_name] == 1 || mins[task_name] > competed_time) ? competed_time : mins[task_name]
                maxs[task_name] = (counts[task_name] == 1 || maxs[task_name] < competed_time) ? competed_time : maxs[task_name]
            }
            END{
                for (i in totals) {
                    # print i, mins[i], maxs[i]
                    "gdate +%s -d " maxs[i] | getline
                    ended = $1
                    "gdate +%s -d " mins[i] | getline
                    started = $1
                    delta = ended - started
                    # print i, "started", mins[i], started, "ended", maxs[i], ended, "delta", delta
                    print i, "|",
                        counts[i], "|",
                        totals[i], "|",
                        totals[i]/counts[i], "|",
                        mins[i], "|",
                        maxs[i], "|",
                        delta, "sec"
                }
            }' \
            "${ALL_TASKS_NAMES_AND_DURATIONS}"
    fi
}

# Output results to stdout in markdown table format.
# Prerequisite: file with timeit results should exist at "${TIMEIT_DURATIONS}"
output_results_timeit_durations() {
    err "::output_results_timeit_durations"

    set +x
    local timeit_absolute
    local timeit_filename
    if ls "${TIMEIT_DURATIONS_DIR}/"* 1> /dev/null 2>&1; then
        echo
        echo "## timeit logger times"
        echo
        echo 'image | pod_label | count | totaltime | meantime'
        echo ':---- | :-------- | ----: | --------: | -------:'
        for timeit_absolute in "${TIMEIT_DURATIONS_DIR}/"*; do
            # echo "${timeit_absolute}"
            timeit_filename=$(basename "${timeit_absolute}")
            echo -n "${IMAGE} | ${timeit_filename} | "
            # for each pod, count number of runs and sum and average the duration
            awk -F ' ' \
                '{totaltime += $1; count += 1} END{print count, "|", totaltime, "msec", "|", totaltime/count, "msec"}' \
                "${timeit_absolute}"
        done
    fi
}


main () {
    prereq
    set_vars

    err "scratch files will be written to ${SCRATCH_ROOT}"

    if [ -z "${SKIP_CODE_PATCH}" ]; then
        if [ -z "${BASE_REF}" ] ; then
            if [ "${UBI}" = "9" ]; then
                BASE_REF="da1a2d71"  # update base image to ubi9/ubi-minimal:9.0.0
            elif [ "${UBI}" = "8" ]; then
                BASE_REF="a63b3b0a"  # last commit before da1a2d71
            fi
        fi

        err "patching additional code over ${BASE_REF} (ubi${UBI})"
        sleep_for 3

        PATCHES=(
            "${PATCHES_DIR}"/01-enable-snythetic-api-4f06f3d1.diff
            "${PATCHES_DIR}"/02-new-perf_test_logging-task-968895af.diff
            "${PATCHES_DIR}"/03-quay-user-in-ansible-c2eee30a.diff
            "${PATCHES_DIR}"/04-worker-12-replicas-f3f0fbe2.diff
            "${PATCHES_DIR}"/05-api-1-replica-31d518e8.diff
            "${PATCHES_DIR}"/06-double-api-memory-c393c9e9.diff
            "${PATCHES_DIR}"/07-double-api-memory-bbc717a1.diff
            "${PATCHES_DIR}"/08-bonfire-deploy-no-remove-resources-a60b5fd0.diff
        )

        pushd "${CLOUDIGRADE_DIR}"
        if ! git diff --no-ext-diff --quiet --exit-code; then
            err "cloudigrade has uncommitted changes; cannot proceed"
            git status
            exit 1
        fi
        git checkout -q "${BASE_REF}" 2>&1 | ts "${TS_FORMAT}" >&2

        for PATCH in "${PATCHES[@]}"; do
            patch -p1 < "${PATCH}" 2>&1 | ts "${TS_FORMAT}" >&2
        done

        GIT_CHERRY_PICK_ARGS=(
            --no-gpg-sign
            --allow-empty
            --keep-redundant-commits
        )
        if [ "${UBI}" = "9" ] && (! head -n1 Dockerfile | grep ubi9); then
            git cherry-pick "${GIT_CHERRY_PICK_ARGS[@]}" --strategy-option theirs da1a2d71b9ec3eb365f29a7b27a7e5c072d81cbb 2>&1 | ts "${TS_FORMAT}" >&2
        elif [ "${UBI}" = "8" ] && (! head -n2 Dockerfile | grep ubi8); then
            err "ubi8 requested but not in Dockerfile; aborting"
            exit 1
        fi
    fi

    [ -z "${SKIP_IMAGE_REBUILD}" ] && build_and_push_image

    [ -z "${SKIP_RESERVATION}" ] && bonfire_reserve
    oc_project

    if [ -z "${SKIP_DEPLOY}" ]; then
        playbook_absent || sleep_for 60 "after destroying old apps before deploying new ones"
        playbook_deploy
        sleep_for 180 "to let the deployments and pods settle down"
    fi

    [ -n "${FORCE_REDEPLOY}" ] && force_redeploy

    IMAGE=$(oc get pods -o jsonpath='{.items[?(.status.phase=="Running")].spec.containers[0].image}' -l pod=cloudigrade-worker | awk '{print $1}')
    err "current deployed image is ${IMAGE}"

    start_time=$(gdate +%s)
    [ -z "${SKIP_SYNTHESIZE}" ] && synthesize_data "$SYNTHETIC_REQUESTS_COUNT" "$SYNTHETIC_INSTANCE_COUNT" "$SYNTHETIC_SINCE_DAYS_AGO"
    [ -z "${SKIP_READY_CHECK}" ] && wait_until_synthetic_data_is_ready

    if [ -z "${SKIP_TASKS}" ]; then
        spawn_logging_tasks # 10 100 20
        sleep_for 30 "to let some api.tasks.perf_test_logging tasks complete"
    fi

    [ -z "${SKIP_TIMEIT}" ] && timeit_logger

    [ -z "${SKIP_LOG_DOWNLOAD}" ] && download_worker_logs
    [ -z "${SKIP_LOG_SIFTING}" ] && extract_logged_tasks

    if [ -z "${SKIP_RESULTS}" ]; then
        output_results_task_durations
        output_results_timeit_durations
    fi
}

main
