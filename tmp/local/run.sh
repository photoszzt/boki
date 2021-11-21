#!/bin/bash

BASE_DIR=$(realpath $(dirname $0)/../..)
echo $BASE_DIR
BUILD_TYPE=debug
# BUILD_TYPE=release

FUNC_IDS="20 30 40"
FPROCESS=$BASE_DIR/../sharedlog-stream/bin/dspbench_handler

ZK_ROOT=${BASE_DIR}/../apache-zookeeper-3.6.3-bin
export ZOO_LOG4J_PROP="WARN,CONSOLE"

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

$BASE_DIR/bin/$BUILD_TYPE/gateway \
    --listen_addr=127.0.0.1 --http_port=$GATEWAY_HTTP_PORT \
    --message_conn_per_worker=2 --tcp_enable_reuseport \
    --func_config_file=$BASE_DIR/tmp/local/func_config.json \
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
        --func_config_file=$BASE_DIR/tmp/local/func_config.json \
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
        MEASURE_PROC=1 $BASE_DIR/bin/$BUILD_TYPE/launcher \
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
