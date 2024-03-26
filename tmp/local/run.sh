#!/bin/bash

BASE_DIR=$(realpath $(dirname $0)/../..)
echo $BASE_DIR
# BUILD_TYPE=debug
BUILD_TYPE=release
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

QUERY="q1"

usage() {
 echo "Usage: $0 [OPTIONS]"
 echo "Options:"
 echo " -h, --help      Display this help message"
 echo " --query         QUERY Specify the name of the query" 
}

has_argument() {
    [[ ("$1" == *=* && -n ${1#*=}) || ( ! -z "$2" && "$2" != -*)  ]];
}

extract_argument() {
  echo "${2:-${1#*=}}"
}

handle_options() {
  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help)
        usage
        exit 0
        ;;
      --query*)
        if ! has_argument $@; then
          echo "query not specified" >&2
          usage
          exit 1
        fi
        QUERY=$(extract_argument $@)
        shift
        ;;
      *)
        echo "Invalid option: $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done
}

handle_options "$@"

FUNC_IDS="20 30 40 60 70"
FPROCESS=$BASE_DIR/../sharedlog-stream/bin/nexmark_handler_debug

docker-compose -f $SCRIPT_DIR/docker-compose.yml up -d

# cd $BASE_DIR/../sharedlog-stream-experiments/mongodb/replica-set
# docker-compose down
# docker volume rm replica-set_mongo-1
# docker volume rm replica-set_mongo-2
# docker volume rm replica-set_mongo-data-primary
# docker-compose up -d
# cd -

ZK_ROOT=${BASE_DIR}/../apache-zookeeper-3.9.1-bin
export ZOO_LOG4J_PROP="WARN,CONSOLE"

if [[ ! -d $ZK_ROOT ]]; then
  wget https://dlcdn.apache.org/zookeeper/zookeeper-3.9.1/apache-zookeeper-3.9.1-bin.tar.gz -O ${BASE_DIR}/../apache-zookeeper-3.9.1-bin.tar.gz
  cd ${BASE_DIR}/../
  tar -xvf ${BASE_DIR}/../apache-zookeeper-3.9.1-bin.tar.gz
  cd -
fi

if [[ ! -d /mnt/inmem ]]; then
  sudo mkdir -p /mnt/inmem
fi
mkdir -p $SCRIPT_DIR/../output

if ! mountpoint -q /mnt/inmem; then
  sudo mount -t tmpfs -o rw,nosuid,nodev tmpfs /mnt/inmem
fi

${ZK_ROOT}/bin/zkCli.sh <<EOF
deleteall /faas
create /faas
create /faas/node
create /faas/view
create /faas/freeze
create /faas/cmd
quit
EOF

PIDS=()

# function kill_all() {
#     for PID in ${PIDS[@]}; do
#         kill -SIGKILL $PID
#     done
# }

# trap kill_all INT

rm -rf $BASE_DIR/tmp/output/*

GATEWAY_HTTP_PORT=8081

FUNC_CONFIG_FILE=$BASE_DIR/../sharedlog-stream-experiments/nexmark_sharedlog/specs/4_ins/${QUERY}.json
$BASE_DIR/bin/$BUILD_TYPE/gateway \
    --listen_addr=127.0.0.1 --http_port=$GATEWAY_HTTP_PORT \
    --message_conn_per_worker=2 --tcp_enable_reuseport \
    --func_config_file=${FUNC_CONFIG_FILE} \
    --async_call_result_path=$BASE_DIR/tmp/output/async_results \
    --v=0 2>$BASE_DIR/tmp/output/gateway.log &
PIDS+=($!)

$BASE_DIR/bin/$BUILD_TYPE/controller \
    --metalog_replicas=3 --userlog_replicas=3 --index_replicas=1 --num_phylogs=1 \
    --v=1 2>$BASE_DIR/tmp/output/controller.log &
PIDS+=($!)

sleep 1

SEQUENCERS="1 2 3"
ENGINES="1 2 3"
STORAGES="1 2 3"

rm -rf /mnt/inmem/faas
rm -rf /tmp/faas

mkdir -p /mnt/inmem/faas

# --slog_sequencer_enable_journal \
# --journal_save_path=/mnt/inmem/faas/journal_seqeucner$i \
for i in $SEQUENCERS; do
    mkdir -p /mnt/inmem/faas/journal_seqeucner$i
    $BASE_DIR/bin/$BUILD_TYPE/sequencer \
        --node_id=$i --message_conn_per_worker=2 \
        --v=1 2>$BASE_DIR/tmp/output/sequencer_node$i.log &
    PIDS+=($!)
done

for i in $ENGINES; do
    $BASE_DIR/bin/$BUILD_TYPE/engine \
        --node_id=$i --enable_shared_log --message_conn_per_worker=2 \
        --func_config_file=${FUNC_CONFIG_FILE} \
        --root_path_for_ipc=/mnt/inmem/faas/engine_node$i \
        --slog_engine_enable_cache \
        --v=1 2>$BASE_DIR/tmp/output/engine_node$i.log &
    PIDS+=($!)
done

# --journal_save_path=/mnt/inmem/faas/journal_storage$i \
# --enforce_cache_miss_for_debug \
# --slog_storage_flusher_threads=2 \
for i in $STORAGES; do
    mkdir -p /mnt/inmem/faas/storage_node$i/db
    mkdir -p /mnt/inmem/faas/journal_storage$i
    $BASE_DIR/bin/$BUILD_TYPE/storage --node_id=$i --message_conn_per_worker=2 \
    --db_path=/mnt/inmem/faas/storage_node$i/db --v=1 2>$BASE_DIR/tmp/output/storage_node$i.log &
    PIDS+=($!)
done

sleep 1

for i in $ENGINES; do
    mkdir -p $BASE_DIR/tmp/output/node$i
    for func in $FUNC_IDS; do
        GOGC=200 FAAS_GO_MAX_PROC_FACTOR=1 FAAS_BUILD_TYPE=release \
        MEASURE_SINK=1 MEASURE_SRC=1 BUFPUSH=1 REDIS_ADDR=127.0.0.1:6666 \
	CREATE_SNAPSHOT=1 PARALLEL_RESTORE=1 ASYNC_SECOND_PHASE=1 \
        $BASE_DIR/bin/$BUILD_TYPE/launcher \
            --root_path_for_ipc=/mnt/inmem/faas/engine_node$i \
            --func_id=$func --fprocess_mode=go \
            --fprocess_output_dir=$BASE_DIR/tmp/output/node$i \
            --fprocess=$FPROCESS \
            --v=1 2>$BASE_DIR/tmp/output/launcher_node${i}_${func}.log &
        PIDS+=($!)
        sleep 0.2
    done
done

sleep 5

${ZK_ROOT}/bin/zkCli.sh create /faas/cmd/start

wait
